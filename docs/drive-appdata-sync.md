# Building serverless multi-device sync on Google Drive `appDataFolder`

A handoff for an agent implementing this in another app. Timeslice's version is the reference —
file paths below point at it — but nothing here is app-specific except the record types.

For the *user-facing* setup (create a client, paste it in), see `google-setup.md`. This document is
the implementation, and it is written trap-first: each section leads with the decision, then the
failure it avoids. Most of those failures took a debugging session to find, and none of them
announce themselves.

## What you get, and what it costs

One hidden Drive folder per app, per user. Each device writes **only its own files**, so two
devices can never write the same byte and merge conflicts are impossible by construction rather
than by locking. No server, no account system, no hosting bill, and the user's data stays in their
own Drive.

The costs, up front:

- **No push.** You poll. Drive's `changes.list` delta makes that cheap (see below), but a change on
  device A reaches device B on B's next poll, not instantly.
- **Last-write-wins on metadata.** Two devices renaming the same task in the same minute: one wins.
  Acceptable for personal-scale data, not for collaborative editing.
- **OAuth is the user's problem once.** A public repo can't ship credentials, so either you
  register a client and distribute it in a signed binary, or every user creates one. Timeslice
  chose the latter; it is two minutes of setup and the reason sync is opt-in.

## 1. Scope: `drive.appdata`, and nothing else

```
https://www.googleapis.com/auth/drive.appdata
```

**The trap that costs an hour:** `drive.file` looks like the right narrow scope and is *not*. It
grants access to app-created files in the **visible** Drive, not the app-data space — so sign-in
succeeds, the token looks perfect, and every single API call returns **403**. The scope must match
the `spaces=appDataFolder` you send on every request.

`appDataFolder` is also genuinely private: files don't appear in the Drive UI, no other app can
list them, and your app can see nothing else the user owns. That is worth saying in your consent
copy, because "let this app into your Drive" is otherwise a big ask.

**There is no folder to create.** Drive resolves the `appDataFolder` alias to a different hidden
folder per app automatically. Do not build a `<yourapp>/` subfolder inside it — it would be one
level of indirection saying what the folder already says, plus a lookup-or-create round trip on
every fresh install and a recovery path for "folder deleted, files weren't". Keep the space flat
and let the **file names** do the organising.

Note for a two-platform app: the space is keyed to the **Cloud project**, not the client id. A
macOS Desktop client and an iOS client in the same project share one `appDataFolder`, which is
exactly what makes cross-device sync work. Two projects would silently sync nothing.

## 2. OAuth with PKCE — `GoogleOAuth.swift`

A desktop/mobile app is a **public client**: the client id is readable from the binary, so security
comes from PKCE (a per-attempt verifier that never leaves the machine), not from secrecy.

```swift
// Consent
client_id, redirect_uri, response_type=code, scope,
code_challenge=<base64url(SHA256(verifier))>, code_challenge_method=S256, state,
access_type=offline,   // without this you get NO refresh token
prompt=consent         // and without this, a user who revoked access is never re-prompted
```

Four things that each look wrong until they bite:

1. **The redirect URI must be byte-identical** in the consent request and the token exchange, or
   Google rejects the exchange. Pass one value into both; don't build the string twice.
   `GoogleOAuth.Redirect` exists only to enforce that.
2. **A Desktop client must still send `client_secret` at the token endpoint** — it answers
   `client_secret is missing.` otherwise — even though PKCE is in use and the "secret" is
   extractable from any installed binary. An **iOS client has no secret**, and sending
   `client_secret=` empty is an error rather than a no-op, so drop empty fields when building the
   form body (`GoogleOAuth.form`).
3. **The redirect differs per client type.** Desktop: `http://127.0.0.1:<port>`, any free port, no
   registration needed — open a one-shot socket and read the request line. iOS: a custom scheme
   that is **not your choice**, it must be the reversed client id
   (`com.googleusercontent.apps.1234-abcd:/oauth`); `yourapp://oauth` is refused for this client
   type.
4. **Distinguish permanent from transient token failures.** The endpoint answers `400` for both a
   dead grant and a malformed request, so match the documented `error` field, not the status:
   `invalid_grant`, `invalid_client`, `unauthorized_client` mean sign the user out; anything else
   means retry later. Get this backwards in either direction and you either sign people out over a
   network blip or retry a revoked credential forever.

On the HTTP layer, keep 401 and 403 apart (`DriveAPI.send`): **401** = stale token, re-auth
actually helps; **403** = authenticated but not permitted, nearly always a scope mismatch. Reporting
403 as "you're not signed in" sends the user to re-authorise something that isn't broken.

## 3. The file model: one payload + one marker per device

Flat names in the root of `appDataFolder`:

| Name | Purpose | Write pattern |
|---|---|---|
| `device-<id>.json` | that device's whole state | rewritten in full on every publish |
| `device-<id>.running` | "I hold the live timer", deleted when it stops | upsert / delete |
| `attachment-<uid>.png` | large immutable blobs | write-once |

The names are **load-bearing**, not cosmetic: a peer reads others' state by listing, filtering on
`hasSuffix(".json")` and `!hasPrefix("device-<mine>")`. One device, one writer, no coordination.

Rewriting the full payload on every publish is the right default at personal scale — it makes the
file a **snapshot with no history to compact**, so a corrupt or partial write is self-healing on the
next sync. Once it's genuinely large, split the immutable bulk into write-once blobs keyed by uid
(that's what `attachment-*` is) rather than inventing a log.

## 4. Drive API specifics — `DriveAPI.swift`

- `spaces=appDataFolder` on **every** list and `changes` call, and `"parents": ["appDataFolder"]` on
  every create. Miss either and you're operating on the visible Drive.
- **Create is a multipart upload** (`uploadType=multipart`, metadata part then bytes);
  **update is `PATCH` with `uploadType=media`** and the raw body. Different endpoints
  (`/upload/drive/v3/files`) from metadata operations (`/drive/v3/files`).
- **Poll with the change delta, not by listing.** `changes/startPageToken` once, then
  `changes?pageToken=…` returns "nothing changed" in one small request. Listing and diffing every
  file on a timer is what makes a poller expensive.
- **Bound your pagination loop** (`for _ in 0..<50`). A malformed `nextPageToken` otherwise spins
  forever on someone else's bug.

### The duplicate-file trap — read this one twice

**Drive permits two files with the same name.** There is no uniqueness constraint. So:

- Keep a `name → id` cache and **PATCH** an existing id instead of creating. Without it, every
  publish appends another copy of the same logical file.
- On PATCH failure, **recreate only on 404**. This is the expensive lesson: catching *all* errors
  and recreating treats a transient failure as "file is gone", so a stale token (401) or a network
  blip forks another copy — every publish. One device ended up with a dozen payload files and
  appeared a dozen times in the device list.
- **Rebuild the cache from what Drive actually holds** (`refreshCache`), don't merge new names in.
  Merging leaves a deleted file's id cached forever.
- Because duplicates can already exist from an earlier bug, **collapse by name, newest wins**
  (`newestPerName`) when reading peers, or you merge the same payload once per copy.
- Delete a device's files **by listing its prefix**, not by cached id — the cache holds one id per
  name, so duplicates are invisible to it and retiring a device leaves copies behind.

## 5. The payload: facts, not operations — `SyncPayload.swift`

```swift
public struct SyncPayload: Codable {
    public var formatVersion: Int = 1
    public var deviceID: String
    public var writtenAt: TimeInterval
    public var intervals: [IntervalRecord]      // immutable facts
    public var tasks: [TaskRecord]              // mutable, carry updatedAt
    public var tombstones: [TombstoneRecord]    // deletes
    public var tags: [TagRecord]?               // everything added later is OPTIONAL
}
```

Four rules that decide whether this ages well:

1. **Ship facts, not operations.** A finished interval is an immutable value, so there's no replay
   order, no idempotency question and no log to compact. Merging is "insert if absent".
2. **Reference by uid, never by local row id.** Ids differ per device; a `projectUID` is the only
   thing both sides agree on. Generate a uid on insert and sync it.
3. **Every field added after v1 is `Optional`.** A missing key otherwise fails the whole decode,
   which silently stops syncing with that peer entirely — the worst failure mode available, because
   nothing errors and data just stops arriving.
4. **Absent ≠ default.** When merging, "the peer didn't mention this field" must not overwrite a
   local value with a default. This is the weekdays-merge lesson: an older peer's *silence* rewrote
   a setting it had never heard of.

Deletes are **tombstones** (uid + deletedAt), not absences. "Not in the payload" is
indistinguishable from "created on the other device a second ago", so without tombstones a delete
either never propagates or resurrects on the next sync.

Mutable records carry `updatedAt` and merge last-write-wins. LWW leans on clocks, so keep it for
metadata only and never for anything you can't afford to lose.

## 6. Concurrency: never touch the transport from the main actor

The single sharpest edge in the whole design.

`SyncTransport` is synchronous (it was designed around file I/O) and bridges to the async Drive API
with a semaphore. Block the main thread there and **the app deadlocks** — the awaited work needs the
main actor to proceed. So:

```swift
private func blocking<T>(_ work: @escaping () async throws -> T) throws -> T {
    guard !Thread.isMainThread else {
        assertionFailure("must not be used from the main thread")   // Debug crashes, Release misbehaves
        throw TransportError.mainThreadMisuse
    }
    // …Task.detached + DispatchSemaphore, ALWAYS with a timeout
    guard sem.wait(timeout: .now() + 30) == .success else { throw TransportError.timedOut }
}
```

An unbounded `wait()` turns any network stall into a permanent hang, which presents as "the app
froze" with no error anywhere.

**The trap that reintroduces itself:** a plain method on a `@MainActor` type inherits that isolation
*even when called from `Task.detached`*. Mark the sync body `nonisolated`, run transport I/O there,
and hop back with `MainActor.run` only for database access (the store isn't `Sendable` and belongs
to a main-actor owner). Symptom to recognise: the app dies immediately after sign-in completes,
because that path ends in a sync.

## 7. Presence, if only one device may act at a time

Timeslice has a one-running-timer invariant across devices. The `.running` marker file carries it:
write on start, delete on stop, treat a marker as live only if fresh.

**Judge freshness by Drive's `modifiedTime`, not the marker's self-reported heartbeat.** A peer's
clock inherits exactly the skew weakness that makes LWW risky; the server timestamp is one clock for
all devices. Fall back to the in-marker value only when Drive omits it.

Whatever your equivalent invariant is, decide it in a **pure, testable policy type**
(`TakeoverPolicy`) rather than inline in the sync loop — it's the piece you'll want to prove with
tests, and it must not require a network to exercise.

## 8. Credentials: never in git, and not all in one place

- **Nothing committed.** GitHub push protection rejects a committed OAuth credential, and a
  credential in public history can never be un-published, only rotated.
- Read at runtime, in order: env vars → a `0600` config file (`~/.config/<app>/env`).
- **A sandboxed platform has no config file to read**, so expose a runtime setter
  (`GoogleOAuth.clientIDOverride`) and let the user paste the id in Settings. On iOS the "Sign in"
  button should stay disabled until it's non-empty — a button that "does nothing" is almost always
  this, not a broken handler.
- **Token storage:** the Keychain is the right home *if* you have a stable signing identity. With
  ad-hoc signing (every rebuild = a new signature) macOS re-prompts for the login password on every
  launch, which is why Timeslice keeps a `0600` file instead. Document the trade-off wherever you
  land, and revisit it once the app ships signed.
- **Rotate anything that ever sat in a working tree.**

## 9. Testing without a network

- **Fake the transport.** `SyncTransport` is a protocol precisely so the merge logic — the part with
  real bugs — is tested against an in-memory implementation. Two fake devices, one dictionary of
  files, full round trip.
- **Pin the crypto to RFC vectors.** PKCE's `S256` is easy to get subtly wrong (base64url vs base64,
  padding), and the failure shows up as an opaque OAuth rejection.
- **Test the merge invariants, not the happy path:** a delete survives a round trip; an older peer's
  missing field doesn't clobber a newer local value; two devices creating the same-named row keep
  both; a payload from a future `formatVersion` is skipped rather than half-applied.
- **Ship a live self-test in the UI.** A "Test" button that does create → list → download → delete
  and reports the result lets a user (and you) confirm the whole chain without a second device. It
  is the fastest triage tool you will have, because it separates "credentials/scope wrong" from
  "merge wrong".

## Build order

Each step is independently verifiable; don't skip ahead.

1. `SyncTransport` protocol + an in-memory fake + merge tests. **No network at all yet.**
2. Payload + merge (uids, tombstones, LWW, optional fields), driven entirely by those tests.
3. OAuth: PKCE, loopback redirect, token refresh, permanent-vs-transient classification.
4. `DriveAPI`: list/create/update/delete with `spaces=appDataFolder`, then the round-trip self-test.
5. `DriveSyncTransport`: id cache, upsert-with-404-only-recreate, newest-per-name.
6. The poll loop with `changes.list`, off the main actor.
7. Presence markers and whatever single-writer invariant you need.
8. Blobs, last — they're an optimisation on payload size.

## Verification checklist

- Sign in, then confirm the token file is `0600` and no credential is in `git log -p`.
- Self-test round trip passes.
- Publish twice from one device → **exactly one** `device-*.json` in the space (this is the
  duplicate bug's canary).
- Kill the network mid-sync → an error message, no hang, no second file.
- Two devices: create on A, appears on B; delete on A, stays deleted on B after two syncs.
- Revoke access in the Google account UI → the app signs out instead of retrying forever.
- Sync from the main thread (temporarily, in a Debug build) → the assertion fires. If it doesn't,
  your isolation annotations are wrong.
