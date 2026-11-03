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

    private struct RecentProbe: Decodable {
        struct Item: Decodable {}
        let uploads: [Item]?
    }

    /// GET /health needs no token, so it cannot prove the token is
    /// right. This probes GET /recent (authenticated): it throws the
    /// server's 401 when the saved token is missing or wrong.
    func verifyToken() async throws {
        var req = try request(for: "recent")
        req.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: req)
        _ = try decode(RecentProbe.self, data: data, response: response)
    }

    // MARK: URL upload

    func uploadFromURL(_ urlString: String) async throws -> UploadResponse {
        var req = try request(for: "url")
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["url": urlString])
        let (data, response) = try await URLSession.shared.data(for: req)
        return try decode(UploadResponse.self, data: data, response: response)
    }

    // MARK: File upload (progress-capable)

    /// Uploads the file at `fileURL` as multipart/form-data (field "file"),
    /// reporting send progress (0...1) on the main actor as it goes.
    func uploadFile(fileURL: URL,
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
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        let disposition = "Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\n"
        body.append(disposition.data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

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
