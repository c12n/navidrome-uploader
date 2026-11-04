//
//  APIClient.swift
//  Navidrome Uploader
//
//  Talks to the Navidrome Uploader companion service:
//
//    GET  /health  -> HealthResponse
//    POST /upload  -> multipart/form-data, field name "file"
//    POST /url     -> JSON {"url": "..."}
//
//  Every request carries "X-Upload-Token: <token>" when a token is set.
//  Server failures surface the real HTTP status and the server's own
//  message — views show that text instead of a blank failure.
//

import Foundation

enum APIError: Error, LocalizedError {
    case invalidBaseURL(String)
    case invalidResponse
    case http(status: Int, message: String)
    case unreadableFile(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let s):
            return "The server URL \u{201C}\(s)\u{201D} is not a valid URL. Check it in Settings."
        case .invalidResponse:
            return "The server returned a response the app could not read."
        case .http(let status, let message):
            return message.isEmpty
                ? "Server error (HTTP \(status))."
                : "Server error (HTTP \(status)): \(message)"
        case .unreadableFile(let name):
            return "Could not read the file \u{201C}\(name)\u{201D}."
        }
    }

    /// Pulls a human message out of an error body: a JSON "detail",
    /// "error" or "message" field when present, otherwise the raw text.
    static func message(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data),
           let dict = object as? [String: Any] {
            for key in ["detail", "error", "message"] {
                if let value = dict[key] as? String, !value.isEmpty { return value }
            }
        }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

struct APIClient {
    let baseURLString: String
    let token: String
    var torboxKey: String = ""
    var premiumizeKey: String = ""

    private var baseURL: URL? {
        let trimmed = baseURLString
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed)
    }

    private func request(for path: String) throws -> URLRequest {
        guard let baseURL else { throw APIError.invalidBaseURL(baseURLString) }
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        if !token.isEmpty {
            req.setValue(token, forHTTPHeaderField: "X-Upload-Token")
        }
        return req
    }

    private func decode<T: Decodable>(_ type: T.Type, data: Data, response: URLResponse) throws -> T {
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            var message = APIError.message(from: data)
            if http.statusCode == 401 {
                message += " Check that the token in Settings matches the server\u{2019}s UPLOAD_TOKEN exactly."
            }
            throw APIError.http(status: http.statusCode, message: message)
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw APIError.http(status: http.statusCode,
                                message: "Unreadable response: \(error.localizedDescription)")
        }
    }

    // MARK: Health

    func health() async throws -> HealthResponse {
        var req = try request(for: "health")
        req.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: req)
        return try decode(HealthResponse.self, data: data, response: response)
    }

    // MARK: Token check

    /// GET /health needs no token, so it cannot prove the token is
    /// right. This probes GET /recent (authenticated): it throws the
    /// server's 401 when the saved token is missing or wrong.
    func verifyToken() async throws {
        _ = try await recentUploads()
    }

    /// GET /recent — the server's own upload log (newest first).
    func recentUploads() async throws -> [ServerRecentEntry] {
        var req = try request(for: "recent")
        req.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: req)
        return try decode(RecentResponse.self, data: data, response: response).uploads
    }

    // MARK: Library operations (0.2.0 server)

    /// POST /scan — the in-app "refresh the library" button.
    func scanLibrary() async throws -> ScanResponse {
        var req = try request(for: "scan")
        req.httpMethod = "POST"
        let (data, response) = try await URLSession.shared.data(for: req)
        return try decode(ScanResponse.self, data: data, response: response)
    }

    /// GET /stats — songs in the library + all-time upload totals.
    func stats() async throws -> StatsResponse {
        var req = try request(for: "stats")
        req.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: req)
        return try decode(StatsResponse.self, data: data, response: response)
    }

    /// POST /check — which of these (name, size) pairs are already in
    /// the library (exact name match, or an exact size match)?
    func checkDuplicates(items: [(name: String, size: Int)]) async throws -> [CheckResponse.Result] {
        var req = try request(for: "check")
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = ["items": items.map {
            ["name": $0.name, "size": $0.size]
        }]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await URLSession.shared.data(for: req)
        return try decode(CheckResponse.self, data: data, response: response).results
    }

    /// GET /duplicates — songs that exist more than once in the
    /// library (same artist + title), biggest copy first per group.
    func duplicates() async throws -> DuplicatesResponse {
        var req = try request(for: "duplicates")
        req.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: req)
        return try decode(DuplicatesResponse.self, data: data, response: response)
    }

    /// POST /delete — remove library files by relative path (the
    /// duplicate finder's cleanup).
    func deleteFiles(_ files: [String]) async throws -> DeleteResponse {
        var req = try request(for: "delete")
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(
            withJSONObject: ["files": files])
        let (data, response) = try await URLSession.shared.data(for: req)
        return try decode(DeleteResponse.self, data: data, response: response)
    }

    /// POST /tracks — fetch specific tracks ("Artist - Title"
    /// strings) via the server's search route. Used to retry the
    /// failed tracks of a URL batch.
    func retryTracks(_ tracks: [String],
                     enrich: Bool = true,
                     lyrics: Bool = true,
                     sort: Bool = false) async throws -> UploadResponse {
        var req = try request(for: "tracks")
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "tracks": tracks, "enrich": enrich, "lyrics": lyrics,
            "sort": sort,
        ])
        let (data, response) = try await URLSession.shared.data(for: req)
        return try decode(UploadResponse.self, data: data, response: response)
    }

    /// GET /in-library — has Navidrome actually indexed this track?
    func inLibrary(title: String, artist: String) async throws -> InLibraryResponse {
        guard let baseURL else { throw APIError.invalidBaseURL(baseURLString) }
        var components = URLComponents(url: baseURL.appendingPathComponent("in-library"),
                                       resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "artist", value: artist),
        ]
        guard let url = components?.url else { throw APIError.invalidBaseURL(baseURLString) }
        var req = URLRequest(url: url)
        if !token.isEmpty {
            req.setValue(token, forHTTPHeaderField: "X-Upload-Token")
        }
        req.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: req)
        return try decode(InLibraryResponse.self, data: data, response: response)
    }

    // MARK: URL upload

    func uploadFromURL(_ urlString: String,
                       enrich: Bool = true,
                       lyrics: Bool = true,
                       sort: Bool = false) async throws -> UploadResponse {
        var req = try request(for: "url")
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Optional debrid keys from Settings: the server uses these for
        // this request when present, else its own configured keys.
        if !torboxKey.isEmpty {
            req.setValue(torboxKey, forHTTPHeaderField: "X-TorBox-Key")
        }
        if !premiumizeKey.isEmpty {
            req.setValue(premiumizeKey, forHTTPHeaderField: "X-Premiumize-Key")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "url": urlString, "enrich": enrich, "lyrics": lyrics, "sort": sort,
        ])
        let (data, response) = try await URLSession.shared.data(for: req)
        return try decode(UploadResponse.self, data: data, response: response)
    }

    // MARK: File upload (progress-capable)

    /// When the app registers a background uploader (see
    /// BackgroundUploads.swift), file uploads run on a background
    /// URLSession so they survive the app being suspended. The share
    /// extension never registers one and uses the inline session.
    /// Signature: (request, bodyFile, progress) -> (data, response).
    nonisolated(unsafe) static var backgroundUploadFunction:
        ((URLRequest, URL, @escaping @MainActor (Double) -> Void)
            async throws -> (Data, URLResponse))?

    /// Uploads the file at `fileURL` as multipart/form-data (field "file",
    /// plus the processing flags as plain form fields), reporting send
    /// progress (0...1) on the main actor as it goes.
    func uploadFile(fileURL: URL,
                    enrich: Bool = false,
                    lyrics: Bool = false,
                    sort: Bool = false,
                    progress: @escaping @MainActor (Double) -> Void) async throws -> UploadResponse {
        var req = try request(for: "upload")
        req.httpMethod = "POST"

        // The picker hands us a security-scoped URL.
        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }

        let fileData: Data
        do {
            fileData = try Data(contentsOf: fileURL)
        } catch {
            throw APIError.unreadableFile(fileURL.lastPathComponent)
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)",
                     forHTTPHeaderField: "Content-Type")

        var body = Data()
        for (field, value) in [("enrich", enrich), ("lyrics", lyrics), ("sort", sort)] {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(field)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value ? "true" : "false")\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        let disposition = "Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\n"
        body.append(disposition.data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        // Background path: the session needs the body in a file.
        if let backgroundUpload = Self.backgroundUploadFunction {
            let bodyFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("naviupload-\(UUID().uuidString).body")
            try body.write(to: bodyFile)
            defer { try? FileManager.default.removeItem(at: bodyFile) }
            let (data, response) = try await backgroundUpload(req, bodyFile, progress)
            return try decode(UploadResponse.self, data: data, response: response)
        }

        let delegate = ProgressUploadDelegate(progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let (data, response) = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
            delegate.continuation = continuation
            let task = session.uploadTask(with: req, from: body)
            delegate.task = task
            task.resume()
        }
        return try decode(UploadResponse.self, data: data, response: response)
    }
}

// MARK: - Upload delegate

/// Per-upload delegate: forwards byte-progress and collects the response
/// body, then resumes the awaiting continuation exactly once.
private final class ProgressUploadDelegate: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate {
    var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    var task: URLSessionUploadTask?
    private var received = Data()
    private var response: URLResponse?
    private let onProgress: @MainActor (Double) -> Void

    init(progress: @escaping @MainActor (Double) -> Void) {
        self.onProgress = progress
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        let fraction = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        Task { @MainActor in self.onProgress(fraction) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.response = response
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        received.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else if let response {
            continuation.resume(returning: (received, response))
        } else {
            continuation.resume(throwing: APIError.invalidResponse)
        }
    }
}
