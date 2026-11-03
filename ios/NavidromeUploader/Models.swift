//
//  Models.swift
//  Navidrome Uploader
//
//  Server response models, the upload-history record, and the two
//  observable stores (settings + history) the views share.
//  The server base URL lives in UserDefaults; the token NEVER does —
//  it is read from / written to the Keychain only (see Keychain.swift).
//

import Foundation
import Observation

// MARK: - Server responses

/// GET /health -> {"status":"ok","library_files":int}
struct HealthResponse: Decodable {
    let status: String
    let libraryFiles: Int

    enum CodingKeys: String, CodingKey {
        case status
        case libraryFiles = "library_files"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Lenient decoding (Viu house pattern): one odd field must not
        // fail the whole response.
        status = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? nil ?? "unknown"
        libraryFiles = (try? c.decodeIfPresent(Int.self, forKey: .libraryFiles)) ?? nil ?? 0
    }
}

/// POST /upload and POST /url -> {"saved_as":str,"size":int,"scan_triggered":bool}
struct UploadResponse: Decodable {
    let savedAs: String
    let size: Int
    let scanTriggered: Bool

    enum CodingKeys: String, CodingKey {
        case savedAs = "saved_as"
        case size
        case scanTriggered = "scan_triggered"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        savedAs = (try? c.decodeIfPresent(String.self, forKey: .savedAs)) ?? nil ?? "unknown"
        size = (try? c.decodeIfPresent(Int.self, forKey: .size)) ?? nil ?? 0
        scanTriggered = (try? c.decodeIfPresent(Bool.self, forKey: .scanTriggered)) ?? nil ?? false
    }
}

// MARK: - History

enum UploadSource: String, Codable {
    case file = "File"
    case url = "URL"
}

struct HistoryItem: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String            // saved filename on the server
    var source: UploadSource
    var date: Date
    var scanTriggered: Bool
    var size: Int               // bytes, 0 when the server did not say
}

// MARK: - Settings store

@Observable
final class SettingsStore {
    static let defaultBaseURL = "https://upload.07051969.xyz"
    private static let baseURLKey = "serverBaseURL"

    /// Base URL of the companion service. Persisted in UserDefaults.
    var baseURLString: String {
        didSet {
            UserDefaults.standard.set(baseURLString, forKey: Self.baseURLKey)
        }
    }

    /// Upload token. Backed by the Keychain, never UserDefaults.
    /// (The in-memory value only mirrors the Keychain for the UI.)
    var token: String {
        didSet {
            Keychain.shared.uploadToken = token.isEmpty ? nil : token
        }
    }

    init() {
        baseURLString = UserDefaults.standard.string(forKey: Self.baseURLKey)
            ?? Self.defaultBaseURL
        token = Keychain.shared.uploadToken ?? ""
    }

    /// The base URL with any trailing slash removed, if it parses.
    var baseURL: URL? {
        let trimmed = baseURLString
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed)
    }

    /// A client configured with the current settings. The token is
    /// trimmed — a token pasted from a terminal easily picks up a
    /// stray space or newline, which the server rightly rejects.
    var client: APIClient {
        APIClient(baseURLString: baseURLString,
                  token: token.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// MARK: - History store

@Observable
final class HistoryStore {
    private static let storageKey = "uploadHistory.v1"

    /// Newest first.
    private(set) var items: [HistoryItem] = []

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([HistoryItem].self, from: data) {
            items = decoded
        }
    }

    func add(name: String, source: UploadSource, response: UploadResponse) {
        let item = HistoryItem(
            name: response.savedAs.isEmpty ? name : response.savedAs,
            source: source,
            date: Date(),
            scanTriggered: response.scanTriggered,
            size: response.size
        )
        items.insert(item, at: 0)
        persist()
    }

    func delete(at offsets: IndexSet) {
        items.remove(atOffsets: offsets)
        persist()
    }

    func clear() {
        items.removeAll()
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}
