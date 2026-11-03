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

/// POST /upload and POST /url. 0.2.0 servers add processing details
/// (enrichment, lyrics, folder, multi-file "files" for playlists and
/// debrid ZIPs); all decoded leniently so 1.x servers still work.
struct UploadResponse: Decodable {
    let savedAs: String
    let size: Int
    let scanTriggered: Bool
    let via: String?
    let alsoSaved: Int
    let folder: String
    let enriched: Bool
    let metadataSource: String?
    let lyricsEmbedded: Bool
    let matchedTitle: String?
    let files: [UploadResponse]

    enum CodingKeys: String, CodingKey {
        case savedAs = "saved_as"
        case size
        case scanTriggered = "scan_triggered"
        case via
        case alsoSaved = "also_saved"
        case folder
        case enriched
        case metadataSource = "metadata_source"
        case lyricsEmbedded = "lyrics_embedded"
        case matchedTitle = "matched_title"
        case files
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        savedAs = (try? c.decodeIfPresent(String.self, forKey: .savedAs)) ?? nil ?? "unknown"
        size = (try? c.decodeIfPresent(Int.self, forKey: .size)) ?? nil ?? 0
        scanTriggered = (try? c.decodeIfPresent(Bool.self, forKey: .scanTriggered)) ?? nil ?? false
        via = (try? c.decodeIfPresent(String.self, forKey: .via)) ?? nil
        alsoSaved = (try? c.decodeIfPresent(Int.self, forKey: .alsoSaved)) ?? nil ?? 0
        folder = (try? c.decodeIfPresent(String.self, forKey: .folder)) ?? nil ?? ""
        enriched = (try? c.decodeIfPresent(Bool.self, forKey: .enriched)) ?? nil ?? false
        metadataSource = (try? c.decodeIfPresent(String.self, forKey: .metadataSource)) ?? nil
        lyricsEmbedded = (try? c.decodeIfPresent(Bool.self, forKey: .lyricsEmbedded)) ?? nil ?? false
        matchedTitle = (try? c.decodeIfPresent(String.self, forKey: .matchedTitle)) ?? nil
        files = (try? c.decodeIfPresent([UploadResponse].self, forKey: .files)) ?? nil ?? []
    }

    /// Short human summary of the server-side processing, for history
    /// rows and result panels.
    var processingNotes: [String] {
        var notes: [String] = []
        if enriched, let matchedTitle {
            notes.append("Tagged as \u{201C}\(matchedTitle)\u{201D}")
        } else if enriched {
            notes.append("Metadata cleaned up")
        }
        if lyricsEmbedded { notes.append("Lyrics embedded") }
        if !folder.isEmpty { notes.append("Filed under \(folder)") }
        if let via { notes.append("via \(via)") }
        return notes
    }
}

/// POST /scan -> {"scan_configured":bool,"scan_triggered":bool}
struct ScanResponse: Decodable {
    let configured: Bool
    let triggered: Bool

    enum CodingKeys: String, CodingKey {
        case configured = "scan_configured"
        case triggered = "scan_triggered"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        configured = (try? c.decodeIfPresent(Bool.self, forKey: .configured)) ?? nil ?? false
        triggered = (try? c.decodeIfPresent(Bool.self, forKey: .triggered)) ?? nil ?? false
    }
}

/// GET /stats -> library size now + all-time NaviUpload totals.
struct StatsResponse: Decodable {
    let libraryFiles: Int
    let uploadedTotal: Int
    let uploadedBytes: Int
    let lastUploadAt: Date?

    enum CodingKeys: String, CodingKey {
        case libraryFiles = "library_files"
        case uploadedTotal = "uploaded_total"
        case uploadedBytes = "uploaded_bytes"
        case lastUploadAt = "last_upload_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        libraryFiles = (try? c.decodeIfPresent(Int.self, forKey: .libraryFiles)) ?? nil ?? 0
        uploadedTotal = (try? c.decodeIfPresent(Int.self, forKey: .uploadedTotal)) ?? nil ?? 0
        uploadedBytes = (try? c.decodeIfPresent(Int.self, forKey: .uploadedBytes)) ?? nil ?? 0
        if let epoch = (try? c.decodeIfPresent(Double.self, forKey: .lastUploadAt)) ?? nil {
            lastUploadAt = Date(timeIntervalSince1970: epoch)
        } else {
            lastUploadAt = nil
        }
    }
}

/// POST /check -> {"results":[{"name","exists","same_size"}]}
struct CheckResponse: Decodable {
    struct Result: Decodable {
        let name: String
        let exists: Bool
        let sameSize: Bool

        enum CodingKeys: String, CodingKey {
            case name
            case exists
            case sameSize = "same_size"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil ?? ""
            exists = (try? c.decodeIfPresent(Bool.self, forKey: .exists)) ?? nil ?? false
            sameSize = (try? c.decodeIfPresent(Bool.self, forKey: .sameSize)) ?? nil ?? false
        }
    }

    let results: [Result]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        results = (try? c.decodeIfPresent([Result].self, forKey: .results)) ?? nil ?? []
    }
}

/// GET /in-library -> {"configured","found","matched_title"}
struct InLibraryResponse: Decodable {
    let configured: Bool
    let found: Bool
    let matchedTitle: String?

    enum CodingKeys: String, CodingKey {
        case configured
        case found
        case matchedTitle = "matched_title"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        configured = (try? c.decodeIfPresent(Bool.self, forKey: .configured)) ?? nil ?? false
        found = (try? c.decodeIfPresent(Bool.self, forKey: .found)) ?? nil ?? false
        matchedTitle = (try? c.decodeIfPresent(String.self, forKey: .matchedTitle)) ?? nil
    }
}

/// One entry of GET /recent (the server's own upload log).
struct ServerRecentEntry: Decodable {
    let savedAs: String
    let size: Int
    let source: String
    let scanTriggered: Bool
    let at: Date
    let folder: String

    enum CodingKeys: String, CodingKey {
        case savedAs = "saved_as"
        case size
        case source
        case scanTriggered = "scan_triggered"
        case at
        case folder
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        savedAs = (try? c.decodeIfPresent(String.self, forKey: .savedAs)) ?? nil ?? "unknown"
        size = (try? c.decodeIfPresent(Int.self, forKey: .size)) ?? nil ?? 0
        source = (try? c.decodeIfPresent(String.self, forKey: .source)) ?? nil ?? "url"
        scanTriggered = (try? c.decodeIfPresent(Bool.self, forKey: .scanTriggered)) ?? nil ?? false
        let epoch = (try? c.decodeIfPresent(Double.self, forKey: .at)) ?? nil ?? 0
        at = Date(timeIntervalSince1970: epoch)
        folder = (try? c.decodeIfPresent(String.self, forKey: .folder)) ?? nil ?? ""
    }
}

struct RecentResponse: Decodable {
    let uploads: [ServerRecentEntry]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uploads = (try? c.decodeIfPresent([ServerRecentEntry].self, forKey: .uploads)) ?? nil ?? []
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
    var folder: String = ""     // Artist/Album when filed into folders
    var fromServer: Bool = false // merged in from the server's own log

    enum CodingKeys: String, CodingKey {
        case id, name, source, date, scanTriggered, size, folder, fromServer
    }

    // Lenient decode so history saved by older versions still loads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? nil ?? UUID()
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil ?? "unknown"
        source = (try? c.decodeIfPresent(UploadSource.self, forKey: .source)) ?? nil ?? .file
        date = (try? c.decodeIfPresent(Date.self, forKey: .date)) ?? nil ?? Date()
        scanTriggered = (try? c.decodeIfPresent(Bool.self, forKey: .scanTriggered)) ?? nil ?? false
        size = (try? c.decodeIfPresent(Int.self, forKey: .size)) ?? nil ?? 0
        folder = (try? c.decodeIfPresent(String.self, forKey: .folder)) ?? nil ?? ""
        fromServer = (try? c.decodeIfPresent(Bool.self, forKey: .fromServer)) ?? nil ?? false
    }

    init(id: UUID = UUID(), name: String, source: UploadSource, date: Date,
         scanTriggered: Bool, size: Int, folder: String = "",
         fromServer: Bool = false) {
        self.id = id
        self.name = name
        self.source = source
        self.date = date
        self.scanTriggered = scanTriggered
        self.size = size
        self.folder = folder
        self.fromServer = fromServer
    }
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

    /// Optional TorBox API key (Settings). Keychain-backed like the
    /// token; sent to the server as X-TorBox-Key on /url requests.
    var torboxKey: String {
        didSet {
            Keychain.shared.torboxKey = torboxKey.isEmpty ? nil : torboxKey
        }
    }

    /// Optional Premiumize API key (Settings). Sent as
    /// X-Premiumize-Key on /url requests.
    var premiumizeKey: String {
        didSet {
            Keychain.shared.premiumizeKey = premiumizeKey.isEmpty ? nil : premiumizeKey
        }
    }

    // MARK: Processing preferences (UserDefaults)

    private static let enrichURLsKey = "processing.enrichURLs"
    private static let enrichFilesKey = "processing.enrichFiles"
    private static let embedLyricsKey = "processing.embedLyrics"
    private static let sortFoldersKey = "processing.sortFolders"
    private static let skipDuplicatesKey = "processing.skipDuplicates"

    /// Identify + retag URL downloads with proper metadata (default on).
    var enrichURLs: Bool {
        didSet { UserDefaults.standard.set(enrichURLs, forKey: Self.enrichURLsKey) }
    }

    /// Same for picked files (default off: albums usually arrive tagged).
    var enrichFiles: Bool {
        didSet { UserDefaults.standard.set(enrichFiles, forKey: Self.enrichFilesKey) }
    }

    /// Fetch lyrics and embed them into the audio file (default on).
    var embedLyrics: Bool {
        didSet { UserDefaults.standard.set(embedLyrics, forKey: Self.embedLyricsKey) }
    }

    /// File uploads under Artist/Album folders (default off).
    var sortFolders: Bool {
        didSet { UserDefaults.standard.set(sortFolders, forKey: Self.sortFoldersKey) }
    }

    /// Check the library before uploading files and skip ones that
    /// are already there (default on).
    var skipDuplicates: Bool {
        didSet { UserDefaults.standard.set(skipDuplicates, forKey: Self.skipDuplicatesKey) }
    }

    init() {
        baseURLString = UserDefaults.standard.string(forKey: Self.baseURLKey)
            ?? Self.defaultBaseURL
        token = Keychain.shared.uploadToken ?? ""
        torboxKey = Keychain.shared.torboxKey ?? ""
        premiumizeKey = Keychain.shared.premiumizeKey ?? ""
        let defaults = UserDefaults.standard
        enrichURLs = defaults.object(forKey: Self.enrichURLsKey) as? Bool ?? true
        enrichFiles = defaults.object(forKey: Self.enrichFilesKey) as? Bool ?? false
        embedLyrics = defaults.object(forKey: Self.embedLyricsKey) as? Bool ?? true
        sortFolders = defaults.object(forKey: Self.sortFoldersKey) as? Bool ?? false
        skipDuplicates = defaults.object(forKey: Self.skipDuplicatesKey) as? Bool ?? true
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
                  token: token.trimmingCharacters(in: .whitespacesAndNewlines),
                  torboxKey: torboxKey.trimmingCharacters(in: .whitespacesAndNewlines),
                  premiumizeKey: premiumizeKey.trimmingCharacters(in: .whitespacesAndNewlines))
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
            size: response.size,
            folder: response.folder
        )
        items.insert(item, at: 0)
        persist()
    }

    /// Merge the server's own upload log (GET /recent) so this device
    /// shows uploads made from Windows or another phone too. Entries
    /// are de-duplicated by name + size + a 10-minute time window.
    func mergeServer(_ entries: [ServerRecentEntry]) {
        var changed = false
        for entry in entries {
            let known = items.contains {
                $0.name == entry.savedAs && $0.size == entry.size
                    && abs($0.date.timeIntervalSince(entry.at)) < 600
            }
            if !known {
                items.append(HistoryItem(
                    name: entry.savedAs,
                    source: entry.source == "file" ? .file : .url,
                    date: entry.at,
                    scanTriggered: entry.scanTriggered,
                    size: entry.size,
                    folder: entry.folder,
                    fromServer: true))
                changed = true
            }
        }
        if changed {
            items.sort { $0.date > $1.date }
            if items.count > 200 { items = Array(items.prefix(200)) }
            persist()
        }
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
