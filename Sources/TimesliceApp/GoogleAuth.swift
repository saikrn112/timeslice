import AppKit
import Foundation
import Security
import TimesliceCore

/// Google sign-in for a native app: PKCE + a one-shot loopback listener.
///
/// No client secret is used or stored — Desktop clients are public, and PKCE is what makes that
/// safe. The refresh token lives in the Keychain; the access token is kept in memory only.
@MainActor
final class GoogleAuth: ObservableObject {
    @Published private(set) var isSignedIn = false
    @Published private(set) var lastError: String?
    /// Set when Google rejects our refresh token (revoked, expired, password changed). Distinct
    /// from "never signed in": the user needs to re-authorise, not discover the feature.
    @Published private(set) var needsReauth = false

    private var accessToken: String?
    private var accessTokenExpiry: Date?
    /// Read from the Keychain once per launch and held in memory.
    ///
    /// Without this, every Drive request re-read the item. On an ad-hoc-signed build macOS asks
    /// for your password on each read (the signature changes per rebuild, so it looks like a
    /// different app), which produced a stream of prompts rather than one.
    private var cachedRefreshToken: String?

    private static let keychainService = "com.timeslice.app.google"
    private static let keychainAccount = "refresh-token"

    /// Scope version. Bumping this invalidates tokens granted under an older scope set, so a
    /// changed scope surfaces as "sign in again" instead of unexplained 403s.
    private static let scopeVersion = 2
    private static let scopeVersionKey = "googleScopeVersion"

    init() {
        let storedVersion = UserDefaults.standard.integer(forKey: Self.scopeVersionKey)
        if storedVersion != Self.scopeVersion, Self.loadRefreshToken() != nil {
            // Token was granted for a different scope; it can authenticate but not authorise.
            Self.deleteRefreshToken()
            cachedRefreshToken = nil
            isSignedIn = false
            needsReauth = true
            lastError = "Google permissions changed — sign in again to finish setting up sync"
            UserDefaults.standard.set(Self.scopeVersion, forKey: Self.scopeVersionKey)
            return
        }
        UserDefaults.standard.set(Self.scopeVersion, forKey: Self.scopeVersionKey)
        cachedRefreshToken = Self.loadRefreshToken()
        isSignedIn = cachedRefreshToken != nil
    }

    // MARK: - Sign in

    /// Opens the system browser for consent and completes the exchange. Throws if the user
    /// cancels or Google refuses.
    func signIn() async throws {
        let pkce = GoogleOAuth.PKCE()
        let state = UUID().uuidString
        let listener: LoopbackListener
        do {
            listener = try LoopbackListener()
        } catch {
            NSLog("[timeslice-auth] listener failed: \(error.localizedDescription)")
            throw error
        }
        defer { listener.stop() }
        NSLog("[timeslice-auth] listening on 127.0.0.1:\(listener.port)")

        let url = GoogleOAuth.authorizationURL(pkce: pkce, redirect: .loopback(port: listener.port), state: state)
        let opened = NSWorkspace.shared.open(url)
        NSLog("[timeslice-auth] opened browser: \(opened)")

        let redirect = try await listener.waitForRedirect()
        NSLog("[timeslice-auth] redirect received (\(redirect.count) bytes)")
        let parsed = GoogleOAuth.parseRedirect(requestLine: redirect)
        if let err = parsed.error {
            NSLog("[timeslice-auth] google returned error: \(err)")
            throw AuthError.denied(err)
        }
        // Verify state before using the code — this is the CSRF check.
        guard parsed.state == state else {
            NSLog("[timeslice-auth] state mismatch: got \(parsed.state ?? "nil")")
            throw AuthError.stateMismatch
        }
        guard let code = parsed.code else {
            NSLog("[timeslice-auth] no code in redirect")
            throw AuthError.noCode
        }
        NSLog("[timeslice-auth] got authorization code, exchanging…")

        let tokens = try await exchange(
            body: GoogleOAuth.tokenRequestBody(code: code, pkce: pkce, redirect: .loopback(port: listener.port)))
        guard let refresh = tokens.refreshToken else {
            NSLog("[timeslice-auth] exchange OK but no refresh_token returned")
            throw AuthError.noRefreshToken
        }
        NSLog("[timeslice-auth] exchange OK, saving refresh token")
        let saved = Self.saveRefreshToken(refresh)
        guard saved == errSecSuccess else {
            NSLog("[timeslice-auth] keychain write failed: \(saved)")
            throw AuthError.keychainFailed(saved)
        }
        // Read it straight back: if this can't be reloaded, `isSignedIn` would be a lie the next
        // time the app launches.
        guard let readBack = Self.loadRefreshToken() else { throw AuthError.keychainFailed(saved) }
        cachedRefreshToken = readBack
        accessToken = tokens.accessToken
        accessTokenExpiry = Date().addingTimeInterval(tokens.expiresIn - 60)
        isSignedIn = true
        lastError = nil
        NSLog("[timeslice-auth] SIGNED IN")
    }

    func signOut() {
        Self.deleteRefreshToken()
        cachedRefreshToken = nil
        accessToken = nil
        accessTokenExpiry = nil
        isSignedIn = false
    }

    /// A valid access token, refreshing when the cached one is near expiry.
    func validAccessToken() async throws -> String {
        if let token = accessToken, let exp = accessTokenExpiry, exp > Date() { return token }
        // In-memory first; only touch the Keychain if we've never read it this launch.
        guard let refresh = cachedRefreshToken ?? Self.loadRefreshToken() else {
            throw AuthError.notSignedIn
        }
        cachedRefreshToken = refresh
        do {
            let tokens = try await exchange(body: GoogleOAuth.refreshRequestBody(refreshToken: refresh))
            accessToken = tokens.accessToken
            accessTokenExpiry = Date().addingTimeInterval(tokens.expiresIn - 60)
            needsReauth = false
            return tokens.accessToken
        } catch {
            // Access tokens expire hourly and are refreshed silently above. Reaching here means
            // the REFRESH token itself was rejected — revoked, or the Google password changed —
            // which no amount of retrying fixes. Drop it and ask for one click.
            Self.deleteRefreshToken()
            cachedRefreshToken = nil
            accessToken = nil
            accessTokenExpiry = nil
            isSignedIn = false
            needsReauth = true
            lastError = "Google sign-in expired — sign in again to resume syncing"
            throw AuthError.notSignedIn
        }
    }

    enum AuthError: LocalizedError {
        case denied(String), stateMismatch, noCode, noRefreshToken, notSignedIn
        case badTokenResponse(String), keychainFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .denied(let e): return "Google sign-in was declined (\(e))"
            case .stateMismatch: return "Sign-in response didn't match the request; try again"
            case .noCode: return "Google didn't return an authorization code"
            case .noRefreshToken: return "Google didn't return a refresh token — revoke access and retry"
            case .notSignedIn: return "Not signed in"
            case .badTokenResponse(let b): return "Token exchange failed: \(b.prefix(160))"
            case .keychainFailed(let st):
                return "Couldn't save the Google token (error \(st))"
            }
        }
    }

    private struct Tokens {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: TimeInterval
    }

    private func exchange(body: Data) async throws -> Tokens {
        var req = URLRequest(url: URL(string: GoogleOAuth.tokenEndpoint)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: req)
        let text = String(decoding: data, as: UTF8.self)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = root["access_token"] as? String else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            NSLog("[timeslice-auth] token endpoint HTTP \(code): \(text.prefix(300))")
            throw AuthError.badTokenResponse(text)
        }
        return Tokens(accessToken: access,
                      refreshToken: root["refresh_token"] as? String,
                      expiresIn: (root["expires_in"] as? Double) ?? 3600)
    }

    // MARK: - Token storage
    //
    // A 0600 file, not the Keychain. Apple's own guidance for ad-hoc signed code (TN3137) is to
    // "store secrets yourself in a file protected by POSIX permissions", because file-based
    // keychain ACLs are keyed to the binary's cdhash: every rebuild presents a new identity, so
    // macOS prompts for the login password each time. (Signed apps like Todoist never see this —
    // a stable Team ID keeps the ACL valid across updates.) The modern data-protection keychain
    // would avoid ACLs entirely but needs a Team-ID access group, returning
    // errSecMissingEntitlement for ad-hoc builds.
    //
    // Trade-off, stated plainly: any process running as this user can read the file, whereas the
    // Keychain encrypts at rest. The token is scoped to `drive.appdata`, so what it can reach is
    // Timeslice's own sync files — not the rest of Drive. Worth revisiting with a Developer ID.

    private static var tokenFileURL: URL {
        TimeslicePaths.defaultDatabaseURL()
            .deletingLastPathComponent()
            .appendingPathComponent("google-token.json")
    }

    @discardableResult
    private static func saveRefreshToken(_ token: String) -> OSStatus {
        let url = tokenFileURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let payload = try JSONSerialization.data(withJSONObject: ["refresh_token": token])
            // Create with 0600 from the outset — never briefly world-readable.
            try payload.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                 ofItemAtPath: url.path)
            // Remove any token left in the Keychain by an earlier build, so there's one source of
            // truth and no stray prompt later.
            migrateAwayFromKeychain()
            return errSecSuccess
        } catch {
            NSLog("[timeslice-auth] token write failed: \(error.localizedDescription)")
            return errSecIO
        }
    }

    private static func loadRefreshToken() -> String? {
        if let data = try? Data(contentsOf: tokenFileURL),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let token = root["refresh_token"] as? String, !token.isEmpty {
            return token
        }
        return nil
    }

    private static func deleteRefreshToken() {
        try? FileManager.default.removeItem(at: tokenFileURL)
        migrateAwayFromKeychain()
    }

    /// Drop the old Keychain item. Reading it would prompt, so this only ever deletes.
    private static func migrateAwayFromKeychain() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ] as CFDictionary)
    }
}

/// Accepts exactly one HTTP request on 127.0.0.1, to catch Google's redirect.
///
/// A loopback listener (rather than a custom URL scheme) is why a Desktop OAuth client needs no
/// pre-registered redirect URIs: any 127.0.0.1 port is accepted, so we take a free one at runtime.
///
/// Uses a plain POSIX socket rather than `NWListener`: the latter failed here with EINVAL and
/// reported port 0, which would have sent Google a redirect URI of `127.0.0.1:0` and broken
/// sign-in with a bare "could not connect".
final class LoopbackListener {
    let port: Int
    private let fd: Int32
    private var finished = false

    init() throws {
        // Bind to a local `sock` first: `fd` is a `let`, and referencing it inside the
        // withUnsafePointer closures below would capture `self` before init completes.
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { throw Failure.noPort }
        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0                       // 0 → the kernel picks a free port
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) {
            bind(sock, UnsafeRawPointer($0).assumingMemoryBound(to: sockaddr.self),
                 socklen_t(MemoryLayout<sockaddr_in>.size))
        }
        guard ok == 0, listen(sock, 1) == 0 else {
            close(sock)
            throw Failure.noPort
        }

        var actual = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &actual) {
            _ = getsockname(sock, UnsafeMutableRawPointer($0).assumingMemoryBound(to: sockaddr.self), &len)
        }
        let assigned = Int(UInt16(bigEndian: actual.sin_port))
        guard assigned != 0 else { close(sock); throw Failure.noPort }
        fd = sock
        port = assigned
    }

    enum Failure: LocalizedError {
        case noPort, timeout
        var errorDescription: String? {
            switch self {
            case .noPort: return "Couldn't open a local port for sign-in"
            case .timeout: return "Sign-in timed out"
            }
        }
    }

    /// Blocks (off the main thread) until the browser hits the redirect, then answers it.
    func waitForRedirect(timeout: TimeInterval = 180) async throws -> String {
        let socketFD = fd
        return try await withCheckedThrowingContinuation { cont in
            var resumed = false
            let lock = NSLock()
            func finishOnce(_ r: Result<String, Error>) {
                lock.lock(); defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                cont.resume(with: r)
            }

            DispatchQueue.global(qos: .userInitiated).async {
                // accept() blocks until the browser connects — hence a background queue.
                let client = accept(socketFD, nil, nil)
                guard client >= 0 else {
                    finishOnce(.failure(Failure.timeout))
                    return
                }
                var buf = [UInt8](repeating: 0, count: 8192)
                let n = read(client, &buf, 8192)
                let line = String(decoding: buf[0..<max(0, n)], as: UTF8.self)
                    .split(separator: "\r\n").first.map(String.init) ?? ""

                // Answer so the browser shows something friendly instead of hanging.
                // window.close() works because the tab was opened by a script-triggered
                // navigation; the message is a fallback for browsers that refuse.
                let body = """
                <html><head><title>Timeslice connected</title></head>
                <body style="font-family:-apple-system;text-align:center;padding:3rem;color:#444">
                <h2>Timeslice is connected</h2>
                <p id="m">Closing…</p>
                <script>
                  setTimeout(function(){
                    window.open('', '_self'); window.close();
                    document.getElementById('m').textContent = 'You can close this tab.';
                  }, 400);
                </script>
                </body></html>
                """
                let http = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                _ = http.withCString { write(client, $0, strlen($0)) }
                close(client)
                finishOnce(.success(line))
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                finishOnce(.failure(Failure.timeout))
            }
        }
    }

    func stop() {
        guard !finished else { return }
        finished = true
        close(fd)
    }
}
