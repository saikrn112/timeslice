import Foundation

/// Google Drive REST calls, scoped to `appDataFolder`.
///
/// `appDataFolder` is a hidden per-app space: files there don't appear in the user's Drive UI and
/// no other app can see them. Combined with the `drive.file` scope, enabling sync grants this app
/// no visibility into anything else in your Drive.
public struct DriveAPI: Sendable {
    public enum DriveError: LocalizedError {
        case http(Int, String)
        case notAuthorized
        case notFound
        case forbidden(String)
        case malformed(String)

        public var errorDescription: String? {
            switch self {
            case .http(let code, let body):
                return "Drive returned \(code): \(body.prefix(200))"
            case .notAuthorized: return "Google sign-in expired — sign in again"
            case .notFound: return "That Drive file no longer exists"
            case .forbidden(let body):
                // Name the likely cause: the granted scopes don't cover what we asked for.
                return body.contains("insufficient")
                    ? "Google Drive permission missing — sign out and sign in again to re-approve"
                    : "Google Drive refused the request: \(body.prefix(160))"
            case .malformed(let what): return "Unexpected Drive response (\(what))"
            }
        }
    }

    /// Supplies a valid access token, refreshing if needed. Injected so this type stays testable
    /// and knows nothing about Keychain or OAuth storage.
    public typealias TokenProvider = @Sendable () async throws -> String

    private let token: TokenProvider
    private let session: URLSession

    public init(token: @escaping TokenProvider, session: URLSession = .shared) {
        self.token = token
        self.session = session
    }

    private static let filesBase = "https://www.googleapis.com/drive/v3/files"
    private static let uploadBase = "https://www.googleapis.com/upload/drive/v3/files"

    // MARK: - Files

    public struct RemoteFile: Sendable, Equatable {
        public let id: String
        public let name: String
        public let modifiedTime: Date?

        public init(id: String, name: String, modifiedTime: Date?) {
            self.id = id; self.name = name; self.modifiedTime = modifiedTime
        }
    }

    /// Everything this app has stored, newest first.
    /// Collapse repeated names to one entry each, keeping the most recently modified.
    ///
    /// Drive permits duplicate names, so one logical file can exist several times over — which is
    /// what made a single device appear once per copy in the device list. Pure and public so the
    /// rule is testable without a network.
    public static func newestPerName(_ files: [RemoteFile]) -> [RemoteFile] {
        var best: [String: RemoteFile] = [:]
        for file in files {
            if let existing = best[file.name],
               (existing.modifiedTime ?? .distantPast) >= (file.modifiedTime ?? .distantPast) {
                continue
            }
            best[file.name] = file
        }
        // Sorted by name so callers get a stable order regardless of dictionary iteration.
        return best.values.sorted { $0.name < $1.name }
    }

    /// Everything this app has stored.
    ///
    /// Pages to the end rather than taking the first 100. A truncated listing is silently harmful
    /// here: a file that falls off the page looks absent, so `upsert` would create yet another copy
    /// of it — the failure compounds itself once duplicates start accumulating.
    public func list() async throws -> [RemoteFile] {
        let iso = ISO8601DateFormatter()
        var out: [RemoteFile] = []
        var pageToken: String?
        // Bounded so a malformed nextPageToken loop can't spin forever.
        for _ in 0..<50 {
            var c = URLComponents(string: Self.filesBase)!
            var items: [URLQueryItem] = [
                .init(name: "spaces", value: "appDataFolder"),
                .init(name: "fields", value: "nextPageToken,files(id,name,modifiedTime)"),
                .init(name: "pageSize", value: "1000"),
            ]
            if let pageToken { items.append(.init(name: "pageToken", value: pageToken)) }
            c.queryItems = items
            let data = try await get(c.url!)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let files = root["files"] as? [[String: Any]] else {
                throw DriveError.malformed("files list")
            }
            out += files.compactMap { f in
                guard let id = f["id"] as? String, let name = f["name"] as? String else { return nil }
                return RemoteFile(id: id, name: name,
                                  modifiedTime: (f["modifiedTime"] as? String).flatMap(iso.date(from:)))
            }
            guard let next = root["nextPageToken"] as? String, !next.isEmpty else { break }
            pageToken = next
        }
        return out
    }

    public func download(id: String) async throws -> Data {
        var c = URLComponents(string: "\(Self.filesBase)/\(id)")!
        c.queryItems = [.init(name: "alt", value: "media")]
        return try await get(c.url!)
    }

    /// Create a file in `appDataFolder`. Returns its id.
    @discardableResult
    public func create(name: String, contents: Data) async throws -> String {
        // Multipart upload: metadata part, then the bytes.
        let boundary = "ts-\(UUID().uuidString)"
        let meta = try JSONSerialization.data(withJSONObject: [
            "name": name, "parents": ["appDataFolder"],
        ])
        var body = Data()
        body.append("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".data(using: .utf8)!)
        body.append(meta)
        body.append("\r\n--\(boundary)\r\nContent-Type: application/json\r\n\r\n".data(using: .utf8)!)
        body.append(contents)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var c = URLComponents(string: Self.uploadBase)!
        c.queryItems = [.init(name: "uploadType", value: "multipart"), .init(name: "fields", value: "id")]
        var req = URLRequest(url: c.url!)
        req.httpMethod = "POST"
        req.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let data = try await send(req)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = root["id"] as? String else { throw DriveError.malformed("create") }
        return id
    }

    /// Replace an existing file's contents.
    public func update(id: String, contents: Data) async throws {
        var c = URLComponents(string: "\(Self.uploadBase)/\(id)")!
        c.queryItems = [.init(name: "uploadType", value: "media")]
        var req = URLRequest(url: c.url!)
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = contents
        _ = try await send(req)
    }

    public func delete(id: String) async throws {
        var req = URLRequest(url: URL(string: "\(Self.filesBase)/\(id)")!)
        req.httpMethod = "DELETE"
        _ = try await send(req)
    }

    // MARK: - Change delta

    /// A token marking "the state of Drive right now", for later delta queries.
    public func startPageToken() async throws -> String {
        let url = URL(string: "https://www.googleapis.com/drive/v3/changes/startPageToken?supportsAllDrives=false")!
        let data = try await get(url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = root["startPageToken"] as? String else { throw DriveError.malformed("startPageToken") }
        return t
    }

    public struct Delta: Sendable {
        public let changedFileIDs: [String]
        public let newPageToken: String
        /// True when nothing changed — the common case, and the reason polling stays cheap.
        public var isEmpty: Bool { changedFileIDs.isEmpty }
    }

    /// What changed since `pageToken`. This is the "poll Drive directly" primitive: one small
    /// request that usually answers "nothing", instead of listing and comparing files.
    public func changes(since pageToken: String) async throws -> Delta {
        var c = URLComponents(string: "https://www.googleapis.com/drive/v3/changes")!
        c.queryItems = [
            .init(name: "pageToken", value: pageToken),
            .init(name: "spaces", value: "appDataFolder"),
            .init(name: "fields", value: "newStartPageToken,nextPageToken,changes(fileId,removed)"),
        ]
        let data = try await get(c.url!)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriveError.malformed("changes")
        }
        let changes = (root["changes"] as? [[String: Any]]) ?? []
        let ids = changes.compactMap { $0["fileId"] as? String }
        let next = (root["newStartPageToken"] as? String)
            ?? (root["nextPageToken"] as? String) ?? pageToken
        return Delta(changedFileIDs: ids, newPageToken: next)
    }

    // MARK: - Plumbing

    private func get(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        return try await send(req)
    }

    private func send(_ request: URLRequest) async throws -> Data {
        var req = request
        req.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw DriveError.malformed("response") }
        switch http.statusCode {
        case 200..<300: return data
        // 401 = the token is stale/invalid → re-auth genuinely helps.
        // 403 = authenticated but not PERMITTED (usually a scope mismatch), where telling the
        // user "not signed in" sends them to re-authorise something that isn't broken.
        case 404: throw DriveError.notFound
        case 401: throw DriveError.notAuthorized
        case 403: throw DriveError.forbidden(String(decoding: data, as: UTF8.self))
        default: throw DriveError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }
    }
}
