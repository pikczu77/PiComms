import Foundation

struct DriveFile: Decodable, Sendable {
    let id: String
    let name: String?
    let createdTime: String?
    let modifiedTime: String?
    let properties: [String: String]?
}

struct DriveUser: Decodable, Sendable {
    let displayName: String?
    let emailAddress: String
}

enum DriveError: LocalizedError {
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .http(let status, let body): "Google Drive zwrócił błąd \(status): \(body.prefix(300))"
        }
    }
}

/// Minimalny klient Google Drive API v3 (REST).
final class DriveClient: @unchecked Sendable {
    private let auth: GoogleAuth
    private let apiBase = URL(string: "https://www.googleapis.com/drive/v3")!
    private let uploadBase = URL(string: "https://www.googleapis.com/upload/drive/v3")!
    private static let fileFields = "id,name,createdTime,modifiedTime,properties"

    init(auth: GoogleAuth) {
        self.auth = auth
    }

    func currentUser() async throws -> DriveUser {
        struct About: Decodable { let user: DriveUser }
        let data = try await send("GET", url(apiBase, "about", ["fields": "user(displayName,emailAddress)"]))
        return try JSONDecoder().decode(About.self, from: data).user
    }

    func listFiles(query: String, orderBy: String? = nil) async throws -> [DriveFile] {
        struct Page: Decodable {
            let files: [DriveFile]
            let nextPageToken: String?
        }
        var result: [DriveFile] = []
        var pageToken: String?
        repeat {
            var params = [
                "q": query,
                "fields": "nextPageToken,files(\(Self.fileFields))",
                "pageSize": "1000",
                "spaces": "drive",
            ]
            if let orderBy { params["orderBy"] = orderBy }
            if let pageToken { params["pageToken"] = pageToken }
            let data = try await send("GET", url(apiBase, "files", params))
            let page = try JSONDecoder().decode(Page.self, from: data)
            result += page.files
            pageToken = page.nextPageToken
        } while pageToken != nil
        return result
    }

    func createFolder(name: String, properties: [String: String]) async throws -> DriveFile {
        let metadata: [String: Any] = [
            "name": name,
            "mimeType": "application/vnd.google-apps.folder",
            "properties": properties,
        ]
        let data = try await send(
            "POST",
            url(apiBase, "files", ["fields": Self.fileFields]),
            body: try JSONSerialization.data(withJSONObject: metadata),
            contentType: "application/json"
        )
        return try JSONDecoder().decode(DriveFile.self, from: data)
    }

    /// Udostępnia plik/folder podanej osobie z prawem edycji (wysyła maila z zaproszeniem).
    func share(fileId: String, with email: String) async throws {
        let permission: [String: Any] = ["type": "user", "role": "writer", "emailAddress": email]
        _ = try await send(
            "POST",
            url(apiBase, "files/\(fileId)/permissions", ["sendNotificationEmail": "true"]),
            body: try JSONSerialization.data(withJSONObject: permission),
            contentType: "application/json"
        )
    }

    func createFile(
        name: String,
        parentId: String,
        properties: [String: String],
        mimeType: String,
        data content: Data
    ) async throws -> DriveFile {
        let metadata: [String: Any] = [
            "name": name,
            "parents": [parentId],
            "properties": properties,
            "mimeType": mimeType,
        ]
        let boundary = "picomms-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n")
        body.append(try JSONSerialization.data(withJSONObject: metadata))
        body.append("\r\n--\(boundary)\r\nContent-Type: \(mimeType)\r\n\r\n")
        body.append(content)
        body.append("\r\n--\(boundary)--\r\n")

        let data = try await send(
            "POST",
            url(uploadBase, "files", ["uploadType": "multipart", "fields": Self.fileFields]),
            body: body,
            contentType: "multipart/related; boundary=\(boundary)"
        )
        return try JSONDecoder().decode(DriveFile.self, from: data)
    }

    func updateFileContent(fileId: String, mimeType: String, data content: Data) async throws -> DriveFile {
        let data = try await send(
            "PATCH",
            url(uploadBase, "files/\(fileId)", ["uploadType": "media", "fields": Self.fileFields]),
            body: content,
            contentType: mimeType
        )
        return try JSONDecoder().decode(DriveFile.self, from: data)
    }

    func download(fileId: String) async throws -> Data {
        try await send("GET", url(apiBase, "files/\(fileId)", ["alt": "media"]))
    }

    // MARK: - HTTP

    private func url(_ base: URL, _ path: String, _ query: [String: String]) -> URL {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        // URLComponents nie koduje „+”, a Google traktuje go jak spację (np. w adresach e-mail).
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    private func send(
        _ method: String,
        _ url: URL,
        body: Data? = nil,
        contentType: String? = nil,
        isRetry: Bool = false
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        let token = try await auth.accessToken(forceRefresh: isRetry)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401, !isRetry {
            return try await send(method, url, body: body, contentType: contentType, isRetry: true)
        }
        guard (200..<300).contains(status) else {
            throw DriveError.http(status, String(decoding: data, as: UTF8.self))
        }
        return data
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}
