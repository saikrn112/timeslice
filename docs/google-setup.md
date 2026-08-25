# Enabling Google Drive sync

Sync is optional. Timeslice works fully offline without it — this is only needed if you want
several devices to stay in step.

The repo deliberately ships **without** OAuth credentials. A credential committed to a public
repo can never be un-published, only rotated, and GitHub's push protection rejects it outright.
So you supply your own, once.

## 1. Create a Google OAuth client (~2 minutes)

1. <https://console.cloud.google.com/> → create or pick a project
2. **APIs & Services → Library → Google Drive API → Enable**
   (a per-project setting; without it every request fails with 403)
3. **APIs & Services → Credentials → Create credentials → OAuth client ID**
   - Application type: **Desktop app**
   - Name: anything
4. **OAuth consent screen** → add the scope
   `https://www.googleapis.com/auth/drive.appdata`
   This is the *narrow* one: a hidden per-app folder, invisible in your Drive and unreadable by
   other apps. Timeslice can see nothing else of yours.
5. If publishing status is **Testing**, add your Google account under **Test users**

## 2. Tell Timeslice about it

```bash
mkdir -p ~/.config/timeslice
cat > ~/.config/timeslice/env <<'ENV'
TIMESLICE_GOOGLE_CLIENT_ID="<your-id>.apps.googleusercontent.com"
TIMESLICE_GOOGLE_CLIENT_SECRET="<your-client-secret>"
ENV
chmod 600 ~/.config/timeslice/env
```

Environment variables of the same names also work and take precedence.

Restart Timeslice, then **Settings → Sync across devices → Sign in with Google**.

> Why a secret at all, for a "public" client? Google's token endpoint requires `client_secret`
> even for Desktop clients using PKCE. It isn't a real secret for an installed app — anyone can
> extract it from a binary — which is precisely why PKCE is mandatory here: the per-attempt
> verifier protects the exchange, and the `127.0.0.1` redirect means a copied credential can't
> receive your authorization codes.

## 3. Verify

**Settings → Test** runs a live round-trip (create → list → download → delete) and reports the
result, so you can confirm sync works without a second device.

## Where things are stored

| What | Where |
|---|---|
| Your OAuth client | `~/.config/timeslice/env` (0600, never committed) |
| Your Google token | `~/Library/Application Support/Timeslice/google-token.json` (0600) |
| Synced data | Google Drive `appDataFolder` — hidden, app-private |

The token is a file rather than a Keychain item because macOS keys Keychain ACLs to the code
signature, and an ad-hoc signed app gets a new signature on every rebuild — which means a login
password prompt every time. With a real Developer ID the Keychain is the better home; see the
note in `Sources/TimesliceCore/GoogleOAuth.swift`.
