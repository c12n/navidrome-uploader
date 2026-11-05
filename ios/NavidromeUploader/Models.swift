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
/// How the server pulled a direct download down (0.5.0): parallel
/// ranged connections when the source supports them.
struct DownloadInfo: Decodable {
    let accelerated: Bool
    let connections: Int

    enum CodingKeys: String, CodingKey {
        case accelerated, connections
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accelerated = (try? c.decodeIfPresent(Bool.self, forKey: .accelerated)) ?? nil ?? false
        connections = (try? c.decodeIfPresent(Int.self, forKey: .connections)) ?? nil ?? 1
    }
}

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
    let failedTracks: [String]
    let download: DownloadInfo?
    // What the song file itself reported (0.6.0 server extraction).
    let bundledArt: Bool
    let durationSeconds: Int
    let featuring: [String]
    let artist: String?
    let album: String?

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
        case failedTracks = "failed_tracks"
        case download
        case bundledArt = "bundled_art"
        case durationSeconds = "duration_seconds"
        case featuring
        case artist
        case album
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
        failedTracks = (try? c.decodeIfPresent([String].self, forKey: .failedTracks)) ?? nil ?? []
        download = (try? c.decodeIfPresent(DownloadInfo.self, forKey: .download)) ?? nil
        bundledArt = (try? c.decodeIfPresent(Bool.self, forKey: .bundledArt)) ?? nil ?? false
        durationSeconds = (try? c.decodeIfPresent(Int.self, forKey: .durationSeconds)) ?? nil ?? 0
        featuring = (try? c.decodeIfPresent([String].self, forKey: .featuring)) ?? nil ?? []
        artist = (try? c.decodeIfPresent(String.self, forKey: .artist)) ?? nil
        album = (try? c.decodeIfPresent(String.self, forKey: .album)) ?? nil
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
        if bundledArt { notes.append("Album art from the upload") }
        if lyricsEmbedded { notes.append("Lyrics embedded") }
        if durationSeconds > 0 {
            notes.append("\(durationSeconds / 60):\(String(format: "%02d", durationSeconds % 60))")
        }
        if !featuring.isEmpty {
            notes.append("feat. \(featuring.joined(separator: ", "))")
        }
        if let download, download.accelerated {
            notes.append("⚡ Accelerated download ×\(download.connections)")
        }
        if !folder.isEmpty { notes.append("Filed under \(folder)") }
        if let via { notes.append("via \(via)") }
        if !failedTracks.isEmpty {
            notes.append("\(failedTracks.count) track\(failedTracks.count == 1 ? "" : "s") couldn't be downloaded")
        }
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

    enum CodingKeys: String, CodingKey {
        case results
    }

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

    enum CodingKeys: String, CodingKey {
        case uploads
    }

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
    /// Tracks of a URL batch that failed to download ("Artist - Title"
    /// strings), kept so History can offer a one-tap retry.
    var failedTracks: [String] = []
    /// The link a URL batch came from ("" for file uploads).
    var sourceURL: String = ""

    enum CodingKeys: String, CodingKey {
        case id, name, source, date, scanTriggered, size, folder, fromServer
        case failedTracks, sourceURL
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
        failedTracks = (try? c.decodeIfPresent([String].self, forKey: .failedTracks)) ?? nil ?? []
        sourceURL = (try? c.decodeIfPresent(String.self, forKey: .sourceURL)) ?? nil ?? ""
    }

    init(id: UUID = UUID(), name: String, source: UploadSource, date: Date,
         scanTriggered: Bool, size: Int, folder: String = "",
         fromServer: Bool = false, failedTracks: [String] = [],
         sourceURL: String = "") {
        self.id = id
        self.name = name
        self.source = source
        self.date = date
        self.scanTriggered = scanTriggered
        self.size = size
        self.folder = folder
        self.fromServer = fromServer
        self.failedTracks = failedTracks
        self.sourceURL = sourceURL
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

    func add(name: String, source: UploadSource, response: UploadResponse,
             failedTracks: [String] = [], sourceURL: String = "") {
        let item = HistoryItem(
            name: response.savedAs.isEmpty ? name : response.savedAs,
            source: source,
            date: Date(),
            scanTriggered: response.scanTriggered,
            size: response.size,
            folder: response.folder,
            failedTracks: failedTracks,
            sourceURL: sourceURL
        )
        items.insert(item, at: 0)
        persist()
    }

    /// After a retry, replace an entry's still-failed track list (an
    /// empty list clears the retry offer).
    func setFailedTracks(id: UUID, tracks: [String]) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].failedTracks = tracks
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

// MARK: - Duplicate finder (GET /duplicates, POST /delete)

struct DuplicateFile: Decodable, Equatable {
    let file: String          // library-relative path
    let size: Int
    let title: String
    let artist: String
    let album: String
    let duration: Double
}

struct DuplicateGroup: Decodable, Equatable {
    let title: String
    let artist: String
    let files: [DuplicateFile]   // biggest copy first — the keeper
    let wastedBytes: Int

    enum CodingKeys: String, CodingKey {
        case title, artist, files
        case wastedBytes = "wasted_bytes"
    }
}

struct DuplicatesResponse: Decodable {
    let groups: [DuplicateGroup]
    let groupCount: Int
    let fileCount: Int
    let wastedBytes: Int
    let scanned: Int

    enum CodingKeys: String, CodingKey {
        case groups, scanned
        case groupCount = "group_count"
        case fileCount = "file_count"
        case wastedBytes = "wasted_bytes"
    }
}

struct DeleteResponse: Decodable {
    struct DeleteError: Decodable {
        let file: String
        let error: String
    }
    let deleted: [String]
    let errors: [DeleteError]
    let scanTriggered: Bool

    enum CodingKeys: String, CodingKey {
        case deleted, errors
        case scanTriggered = "scan_triggered"
    }
}

// MARK: - Keys backup (JSON export / import)

/// Everything needed to set the app up on another device: server,
/// upload token and both debrid keys. Exported as a JSON file from
/// Settings and imported back the same way. The file contains
/// secrets — the UI says so wherever it's offered.
struct KeysBackup: Codable {
    var app: String = "NaviUpload"
    var version: Int = 1
    var server: String
    var token: String
    var torboxKey: String
    var premiumizeKey: String

    enum CodingKeys: String, CodingKey {
        case app, version, server, token
        case torboxKey = "torbox_key"
        case premiumizeKey = "premiumize_key"
    }

    init(server: String, token: String, torboxKey: String,
         premiumizeKey: String) {
        self.server = server
        self.token = token
        self.torboxKey = torboxKey
        self.premiumizeKey = premiumizeKey
    }

    // Lenient: fields a future version adds (or leaves out) must not
    // break an import.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        app = (try? c.decodeIfPresent(String.self, forKey: .app)) ?? nil ?? "NaviUpload"
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? nil ?? 1
        server = (try? c.decodeIfPresent(String.self, forKey: .server)) ?? nil ?? ""
        token = (try? c.decodeIfPresent(String.self, forKey: .token)) ?? nil ?? ""
        torboxKey = (try? c.decodeIfPresent(String.self, forKey: .torboxKey)) ?? nil ?? ""
        premiumizeKey = (try? c.decodeIfPresent(String.self, forKey: .premiumizeKey)) ?? nil ?? ""
    }
}

extension SettingsStore {
    /// Snapshot of the current setup for the JSON backup file.
    func makeBackup() -> KeysBackup {
        KeysBackup(
            server: baseURLString
                .trimmingCharacters(in: .whitespacesAndNewlines),
            token: token.trimmingCharacters(in: .whitespacesAndNewlines),
            torboxKey: torboxKey
                .trimmingCharacters(in: .whitespacesAndNewlines),
            premiumizeKey: premiumizeKey
                .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Apply an imported backup. Empty fields in the file leave the
    /// current values alone, except the server, which only applies
    /// when the file actually carries one.
    func applyBackup(_ backup: KeysBackup) {
        if !backup.server.isEmpty { baseURLString = backup.server }
        if !backup.token.isEmpty { token = backup.token }
        if !backup.torboxKey.isEmpty { torboxKey = backup.torboxKey }
        if !backup.premiumizeKey.isEmpty {
            premiumizeKey = backup.premiumizeKey
        }
    }

    /// The backup as pretty JSON data for the export file.
    func backupJSONData() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(makeBackup())
    }
}

// MARK: - Update checker

/// A newer NaviUpload release spotted on GitHub.
struct AvailableUpdate: Equatable {
    let version: String       // "0.5.0" (no leading v)
    let pageURL: URL
}

/// Asks GitHub for the latest release of c12n/navidrome-uploader at
/// most every 6 hours and caches the answer, so the Upload tab can
/// show a small "update available" banner. Purely informational —
/// installing still happens through the usual sideload route.
enum UpdateChecker {
    private static let apiURL = URL(
        string: "https://api.github.com/repos/c12n/navidrome-uploader/releases/latest")!
    private static let lastCheckKey = "update.lastCheck"
    private static let cachedVersionKey = "update.cachedVersion"
    private static let cachedURLKey = "update.cachedURL"

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "0"
    }

    /// The cached or freshly fetched update, if one is newer than
    /// the running app.
    static func availableUpdate() async -> AvailableUpdate? {
        let defaults = UserDefaults.standard
        let last = defaults.object(forKey: lastCheckKey) as? Date
        if last == nil || Date().timeIntervalSince(last!) > 6 * 3600 {
            defaults.set(Date(), forKey: lastCheckKey)
            if let (data, _) = try? await URLSession.shared.data(from: apiURL),
               let json = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
               let tag = json["tag_name"] as? String,
               let page = json["html_url"] as? String {
                let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                defaults.set(version, forKey: cachedVersionKey)
                defaults.set(page, forKey: cachedURLKey)
            }
        }
        guard let version = defaults.string(forKey: cachedVersionKey),
              let page = defaults.string(forKey: cachedURLKey),
              let url = URL(string: page),
              isNewer(version, than: currentVersion) else { return nil }
        return AvailableUpdate(version: version, pageURL: url)
    }

    /// Numeric dotted-version compare ("0.10.0" > "0.9.9").
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
