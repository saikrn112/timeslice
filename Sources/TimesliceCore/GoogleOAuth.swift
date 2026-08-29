import Foundation

/// PKCE OAuth for a native ("Desktop") Google client.
///
/// Desktop clients are **public**: the client id ships in the binary and there is no usable
/// secret, so security comes from PKCE — a per-attempt verifier that never leaves this machine.
/// Google may display a secret for Desktop clients; it is deliberately not used here.
public enum GoogleOAuth {

    /// OAuth client credentials, resolved at runtime — never committed.
    ///
    /// Looked up in order:
    ///   1. `TIMESLICE_GOOGLE_CLIENT_ID` / `TIMESLICE_GOOGLE_CLIENT_SECRET` env vars
    ///   2. `~/.config/timeslice/env` (shell-style `KEY="value"` lines)
    ///
    /// Kept out of source because GitHub push protection rightly rejects a committed OAuth
    /// credential, and because a credential in public git history can never be un-published — only
    /// rotated. A fork supplies its own client; see docs/google-setup.md.
    ///
    /// Google requires `client_secret` at the TOKEN endpoint even for a Desktop client using PKCE
    /// (it answers "client_secret is missing." otherwise), so it can't simply be dropped. For an
    /// installed app it isn't a true secret — anyone can read it out of the binary — which is
    /// exactly why PKCE is mandatory for this client type: the per-attempt verifier is what
    /// protects the exchange. The redirect is 127.0.0.1, so a copied credential cannot receive
    /// anyone else's authorization codes, and `drive.appdata` reaches nothing but files this app
    /// created.
    public static var clientID: String { credential("CLIENT_ID") }
    public static var clientSecret: String { credential("CLIENT_SECRET") }

    /// True when sync can be offered at all. Without credentials the feature stays hidden rather
    /// than failing at the consent screen.
    ///
    /// The secret is required only for the Desktop client type the Mac uses; an iOS client has none,
    /// so demanding one there would hide sync permanently.
    public static var isConfigured: Bool {
        #if os(macOS)
        return !clientID.isEmpty && !clientSecret.isEmpty
        #else
        return !clientID.isEmpty
        #endif
    }

    public static let configFilePath = "~/.config/timeslice/env"

    private static func credential(_ key: String) -> String {
        let envKey = "TIMESLICE_GOOGLE_\(key)"
        if let v = ProcessInfo.processInfo.environment[envKey], !v.isEmpty { return v }
        return configFileValues[envKey] ?? ""
    }

    /// Parsed once — this is read on every token request.
    private static let configFileValues: [String: String] = {
        let path = (configFilePath as NSString).expandingTildeInPath
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[trimmed.startIndex..<eq])
                .replacingOccurrences(of: "export ", with: "")
                .trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: eq)...])
                .trimmingCharacters(in: .whitespaces)
            // Strip one layer of matching quotes.
            if value.count >= 2, let f = value.first, let l = value.last, f == l,
               f == "\"" || f == "'" {
                value = String(value.dropFirst().dropLast())
            }
            out[key] = value
        }
        return out
    }()

    /// `drive.appdata` = the hidden per-app folder ONLY.
    ///
    /// This must match the `spaces=appDataFolder` used by DriveAPI. Requesting `drive.file`
    /// instead granted access to app-created files in the *visible* Drive, not the app-data
    /// space — so every call came back 403 while sign-in itself looked fine.
    ///
    /// It's also the narrower of the two: files are invisible in the user's Drive UI, no other
    /// app can read them, and this app can see nothing else of theirs.
    public static let scope = "https://www.googleapis.com/auth/drive.appdata"

    public static let authEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    public static let tokenEndpoint = "https://oauth2.googleapis.com/token"

    /// One login attempt's PKCE pair.
    public struct PKCE: Sendable {
        public let verifier: String
        public let challenge: String

        public init() {
            // 43–128 chars of unreserved characters, per RFC 7636.
            let chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
            var v = ""
            for _ in 0..<64 {
                v.append(chars.randomElement()!)
            }
            verifier = v
            challenge = Self.s256(v)
        }

        /// base64url(SHA256(verifier)), no padding.
        private static func s256(_ input: String) -> String {
            var hash = [UInt8](repeating: 0, count: 32)
            SHA256.hash(Array(input.utf8), into: &hash)
            return Data(hash).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
    }

    /// Where Google sends the authorization code back to.
    ///
    /// Abstracted because the two platforms cannot share one answer. A Mac can open a socket and
    /// catch the redirect; an iPhone cannot usefully run a web server, and `ASWebAuthenticationSession`
    /// only reports back through a custom URL scheme. The redirect URI must be byte-identical in the
    /// consent request and the token exchange or Google rejects the exchange, so it is one value
    /// passed to both rather than a string built twice.
    public enum Redirect: Sendable, Equatable {
        /// Desktop client: Google accepts any `http://127.0.0.1:<port>`, which is why this client
        /// type needs no registered redirect URI — the app takes a free port at runtime.
        case loopback(port: Int)

        /// Installed-app client (what iOS requires). The scheme is **not** arbitrary: Google only
        /// accepts the reversed client id, e.g.
        /// `com.googleusercontent.apps.1234-abcd:/oauth`. A `timeslice://oauth` scheme — which the
        /// design note proposed — is refused for this client type.
        case customScheme(String)

        public var uriString: String {
            switch self {
            case .loopback(let port): return "http://127.0.0.1:\(port)"
            case .customScheme(let uri): return uri
            }
        }
    }

    /// Consent URL for `redirect`.
    public static func authorizationURL(pkce: PKCE, redirect: Redirect, state: String) -> URL {
        var c = URLComponents(string: authEndpoint)!
        c.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirect.uriString),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scope),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            // Needed to get a refresh token at all, and to re-prompt if the user revoked access.
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ]
        return c.url!
    }

    public static func tokenRequestBody(code: String, pkce: PKCE, redirect: Redirect) -> Data {
        form([
            "client_id": clientID,
            // Omitted entirely when empty: a Desktop client must send it (Google answers
            // "client_secret is missing." otherwise), but an iOS client has none and sending an
            // empty one is an error rather than a no-op.
            "client_secret": clientSecret,
            "code": code,
            "code_verifier": pkce.verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirect.uriString,
        ])
    }

    public static func refreshRequestBody(refreshToken: String) -> Data {
        form([
            "client_id": clientID,
            "client_secret": clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ])
    }

    /// Empty values are dropped rather than sent blank, so a client type that has no
    /// `client_secret` (iOS) doesn't transmit `client_secret=` and get rejected for it.
    private static func form(_ fields: [String: String]) -> Data {
        var c = URLComponents()
        c.queryItems = fields
            .filter { !$0.value.isEmpty }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        return Data((c.percentEncodedQuery ?? "").utf8)
    }

    /// Pull `code` (or `error`) out of the browser's redirect request line.
    public static func parseRedirect(requestLine: String) -> (code: String?, state: String?, error: String?) {
        // e.g. "GET /?code=4/abc&state=xyz HTTP/1.1"
        guard let path = requestLine.split(separator: " ").dropFirst().first,
              let comps = URLComponents(string: "http://127.0.0.1\(path)") else {
            return (nil, nil, "unparseable redirect")
        }
        let items = comps.queryItems ?? []
        return (items.first { $0.name == "code" }?.value,
                items.first { $0.name == "state" }?.value,
                items.first { $0.name == "error" }?.value)
    }
}

/// Minimal SHA-256 so TimesliceCore stays dependency-free (CryptoKit would pull in a framework
/// this UI-free module otherwise doesn't need, and must remain portable to iOS).
enum SHA256 {
    static func hash(_ message: [UInt8], into out: inout [UInt8]) {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                           0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        let k: [UInt32] = [
            0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
            0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
            0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
            0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
            0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
            0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
            0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
            0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2]

        var msg = message
        let bitLen = UInt64(message.count) * 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for i in (0..<8).reversed() { msg.append(UInt8((bitLen >> (UInt64(i) * 8)) & 0xff)) }

        for chunk in stride(from: 0, to: msg.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 {
                let o = chunk + i * 4
                w[i] = (UInt32(msg[o]) << 24) | (UInt32(msg[o+1]) << 16)
                     | (UInt32(msg[o+2]) << 8) | UInt32(msg[o+3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i-15], 7) ^ rotr(w[i-15], 18) ^ (w[i-15] >> 3)
                let s1 = rotr(w[i-2], 17) ^ rotr(w[i-2], 19) ^ (w[i-2] >> 10)
                w[i] = w[i-16] &+ s0 &+ w[i-7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3]
            var e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ S1 &+ ch &+ k[i] &+ w[i]
                let S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = S0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1
                d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        }
        for i in 0..<8 {
            out[i*4]   = UInt8((h[i] >> 24) & 0xff)
            out[i*4+1] = UInt8((h[i] >> 16) & 0xff)
            out[i*4+2] = UInt8((h[i] >> 8) & 0xff)
            out[i*4+3] = UInt8(h[i] & 0xff)
        }
    }

    private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
}

/// Test-visible alias for the internal hash, so PKCE can be pinned to RFC vectors.
public enum SHA256Public {
    public static func hash(_ message: [UInt8], into out: inout [UInt8]) {
        SHA256.hash(message, into: &out)
    }
}
