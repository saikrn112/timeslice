import AuthenticationServices
import Foundation
import Security
import TimesliceCore
import UIKit

/// Google sign-in on iOS: PKCE through `ASWebAuthenticationSession`, refresh token in the Keychain.
///
/// The Mac runs a loopback HTTP listener and catches the redirect on `127.0.0.1`. A phone can't do
/// that usefully — the app is backgrounded the moment the browser opens, so a socket it owns may be
/// suspended before the redirect lands. `ASWebAuthenticationSession` is the supported equivalent: the
/// *system* watches for a redirect to our scheme and hands the URL back.
///
/// Two consequences worth knowing:
///
/// - **No `client_secret`.** An iOS OAuth client has none, and sending an empty one is an error rather
///   than a no-op — which is why `GoogleOAuth.form` drops empty fields.
/// - **The scheme is not a free choice.** Google accepts only the reversed client id for this client
///   type (`com.googleusercontent.apps.1234-abcd`), so it's derived rather than configured. The
///   original design note's `timeslice://oauth` would have been refused.
///
/// It also needs **no `CFBundleURLTypes` entry**: `ASWebAuthenticationSession` intercepts the callback
/// itself from `callbackURLScheme`. That's what lets the client id be pasted at runtime instead of
/// baked in — a scheme declared in Info.plist would have to be known at build time.
@MainActor
final class GoogleAuthiOS: NSObject, ObservableObject {
    static let shared = GoogleAuthiOS()

    @Published private(set) var isSignedIn = false
    @Published private(set) var lastError: String?

    /// Cached access token and its expiry. Access tokens last an hour; the refresh token is the
    /// durable credential and is the only thing persisted.
    private var accessToken: String?
    private var accessTokenExpiry: Date?

    private let keychainService = "com.timeslice.ios.google"
    private let keychainAccount = "refresh-token"

    private var session: ASWebAuthenticationSession?

    private override init() {
        super.init()
        isSignedIn = loadRefreshToken() != nil
    }

    // MARK: - Sign in / out

    func signIn() async {
        lastError = nil
        let id = GoogleOAuth.clientID
        guard !id.isEmpty else {
            lastError = "No client ID set."
            return
        }
        guard let redirect = GoogleOAuth.iOSRedirect(id),
              let scheme = GoogleOAuth.reversedClientID(id) else {
            lastError = "That doesn't look like a Google iOS client ID "
                      + "(it should end in .apps.googleusercontent.com)."
            return
        }

        let pkce = GoogleOAuth.PKCE()
        let state = UUID().uuidString
        let url = GoogleOAuth.authorizationURL(pkce: pkce, redirect: redirect, state: state)

        do {
            let callback = try await present(url: url, callbackScheme: scheme)
            // `state` is checked before the code is used: without it a malicious app that could reach
            // our callback could feed us an authorization code from a different session.
            let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if let error = items.first(where: { $0.name == "error" })?.value {
                lastError = "Google returned: \(error)"
                return
            }
            guard items.first(where: { $0.name == "state" })?.value == state else {
                lastError = "Sign-in state mismatch — nothing was changed."
                return
            }
            guard let code = items.first(where: { $0.name == "code" })?.value else {
                lastError = "No authorization code in the callback."
                return
            }

            let body = GoogleOAuth.tokenRequestBody(code: code, pkce: pkce, redirect: redirect)
            let tokens = try await postForm(body)
            guard let refresh = tokens["refresh_token"] as? String else {
                // Google omits the refresh token when the user has already granted consent and
                // `prompt=consent` didn't force a re-approval. `authorizationURL` always sends
                // `access_type=offline` and `prompt=consent`, so this indicates a real problem.
                lastError = "Google didn't return a refresh token. Revoke access for Timeslice in "
                          + "your Google account and try again."
                return
            }
            try saveRefreshToken(refresh)
            cache(tokens)
            isSignedIn = true
            SyncController.shared.use(transport: makeTransport())
            await SyncController.shared.syncOnce()
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            // User dismissed the sheet — not an error worth showing.
        } catch {
            lastError = error.localizedDescription
        }
    }

    func signOut() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ] as CFDictionary)
        accessToken = nil
        accessTokenExpiry = nil
        isSignedIn = false
    }

    /// Wire this into the sync controller. Called on sign-in and at launch when a token already
    /// exists, so `SyncController` has a transport without knowing anything about OAuth.
    func makeTransport() -> SyncTransport {
        DriveSyncTransport(api: DriveAPI(token: { [weak self] in
            guard let self else { throw AuthError.signedOut }
            return try await self.validAccessToken()
        }))
    }

    /// Restore sync at launch if a refresh token is already stored.
    func restoreIfPossible() {
        guard loadRefreshToken() != nil, !GoogleOAuth.clientID.isEmpty else { return }
        isSignedIn = true
        SyncController.shared.use(transport: makeTransport())
    }

    // MARK: - Tokens

    enum AuthError: LocalizedError {
        case signedOut
        case tokenRefreshFailed(String)

        var errorDescription: String? {
            switch self {
            case .signedOut: return "Not signed in to Google."
            case .tokenRefreshFailed(let detail): return "Couldn't refresh Google access: \(detail)"
            }
        }
    }

    /// A usable access token, refreshing when the cached one is missing or close to expiry.
    ///
    /// Refreshed 60s early rather than on expiry: a token that expires mid-request fails the request,
    /// and sync would then look flaky rather than merely slow.
    private func validAccessToken() async throws -> String {
        if let accessToken, let expiry = accessTokenExpiry, expiry > Date().addingTimeInterval(60) {
            return accessToken
        }
        guard let refresh = loadRefreshToken() else { throw AuthError.signedOut }
        let tokens = try await postForm(GoogleOAuth.refreshRequestBody(refreshToken: refresh))
        guard let token = tokens["access_token"] as? String else {
            throw AuthError.tokenRefreshFailed("no access_token in the response")
        }
        cache(tokens)
        return token
    }

    private func cache(_ tokens: [String: Any]) {
        accessToken = tokens["access_token"] as? String
        let seconds = (tokens["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        accessTokenExpiry = Date().addingTimeInterval(seconds)
    }

    private func postForm(_ body: Data) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: GoogleOAuth.tokenEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let detail = String(decoding: data, as: UTF8.self).prefix(200)
            throw AuthError.tokenRefreshFailed(String(detail))
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    // MARK: - Keychain

    private func saveRefreshToken(_ token: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = Data(token.utf8)
        // Available after first unlock, not while locked: a background refresh must be able to read
        // it, but it should never be readable from a locked device.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AuthError.tokenRefreshFailed("keychain write failed (\(status))")
        }
    }

    private func loadRefreshToken() -> String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ] as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Presentation

    private func present(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url, callbackURLScheme: callbackScheme
            ) { callback, error in
                if let callback {
                    continuation.resume(returning: callback)
                } else {
                    continuation.resume(throwing: error ?? AuthError.signedOut)
                }
            }
            session.presentationContextProvider = self
            // A fresh session each time, so signing in as a different account doesn't silently reuse
            // the previous one's cookies.
            session.prefersEphemeralWebBrowserSession = true
            self.session = session
            session.start()
        }
    }
}

extension GoogleAuthiOS: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first ?? ASPresentationAnchor()
    }
}
