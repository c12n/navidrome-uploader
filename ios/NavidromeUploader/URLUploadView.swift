//
//  URLUploadView.swift
//  Navidrome Uploader
//
//  Tab 2: paste one link — or many, one per line — and the server
//  downloads each into the Navidrome library. Direct audio links are
//  fetched as-is; hoster links go through TorBox / Premiumize when a
//  key is set; YouTube / SoundCloud / playlist links are handled
//  server-side with yt-dlp (playlists expand to every track).
//
//  After a download whose scan was triggered, the app checks back
//  with Navidrome ("In your library ✓") so a save is not just a hope.
//

import SwiftUI
import UIKit

private struct LinkRow: Identifiable {
    enum State: Equatable {
        case pending, working, done, failed(String)
    }

    let id = UUID()
    let url: String
    var state: State = .pending
    var response: UploadResponse?
    var libraryNote: String?
}

struct URLUploadView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(HistoryStore.self) private var history

    @State private var linksText = ""
    @State private var rows: [LinkRow] = []
    @State private var isWorking = false

    /// Links parsed from the text box: whitespace/newline separated,
    /// http(s) only, de-duplicated, order preserved.
    private var parsedLinks: [String] {
        var seen = Set<String>()
        return linksText
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("http://") || $0.hasPrefix("https://") }
            .filter { seen.insert($0).inserted }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Links") {
                    TextEditor(text: $linksText)
                        .frame(minHeight: 76)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button {
                        if let pasted = UIPasteboard.general.string {
                            linksText = pasted
                        }
                    } label: {
                        Label("Paste", systemImage: "doc.on.clipboard")
                    }
                    .disabled(isWorking)
                } footer: {
                    Text("One link per line. A YouTube playlist link adds every track in it (up to 50).")
                }

                Section {
                    Button {
                        startDownloads()
                    } label: {
                        HStack {
                            Spacer()
                            if isWorking {
                                ProgressView()
                                Text("Downloading\u{2026}").padding(.leading, 6)
                            } else {
                                Text(parsedLinks.count > 1
                                     ? "Download \(parsedLinks.count) links"
                                     : "Download to Navidrome")
                                    .font(.headline)
                            }
                            Spacer()
                        }
                    }
                    .disabled(isWorking || parsedLinks.isEmpty)
                }

                if !rows.isEmpty {
                    Section("Results") {
                        ForEach(rows) { row in
                            linkRow(row)
                        }
                    }
                }

                Section {
                    Text("Direct audio links (mp3, m4a, flac, wav, ogg, opus, aac) are fetched as-is. Links on supported file hosters are fetched through your TorBox or Premiumize account when a key is set. YouTube and other page links are handled on the server with yt-dlp. With metadata cleanup on (Settings), songs are identified and tagged, and lyrics are embedded into the file.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("URL")
        }
    }

    @ViewBuilder
    private func linkRow(_ row: LinkRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.url)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            switch row.state {
            case .pending:
                Text("Waiting")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            case .working:
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Downloading on the server\u{2026}")
                        .font(.subheadline)
                }
            case .done:
                if let response = row.response {
                    Label("Saved \u{2014} \(response.savedAs)",
                          systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.green)
                        .lineLimit(2)
                    let notes = response.processingNotes
                    if response.alsoSaved > 0 {
                        Text("+ \(response.alsoSaved) more file\(response.alsoSaved == 1 ? "" : "s") from this link")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else if !notes.isEmpty {
                        Text(notes.joined(separator: " \u{00B7} "))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let libraryNote = row.libraryNote {
                        Text(libraryNote)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            case .failed(let message):
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .lineLimit(4)
            }
        }
        .padding(.vertical, 2)
    }

    private func startDownloads() {
        let links = parsedLinks
        guard !links.isEmpty else { return }
        rows = links.map { LinkRow(url: $0) }
        isWorking = true
        let client = settings.client
        let enrich = settings.enrichURLs
        let lyrics = settings.embedLyrics
        let sort = settings.sortFolders

        Task { @MainActor in
            for index in rows.indices {
                rows[index].state = .working
                let target = rows[index].url
                do {
                    let response = try await client.uploadFromURL(
                        target, enrich: enrich, lyrics: lyrics, sort: sort)
                    rows[index].state = .done
                    rows[index].response = response
                    history.add(name: target, source: .url, response: response)
                    for extra in response.files.dropFirst() {
                        history.add(name: extra.savedAs, source: .url,
                                    response: extra)
                    }
                    verifyInLibrary(rowAt: index, response: response,
                                    client: client)
                } catch {
                    rows[index].state = .failed(
                        (error as? LocalizedError)?.errorDescription
                            ?? error.localizedDescription)
                }
            }
            isWorking = false
        }
    }

    /// "Did it actually land?" — when the save triggered a scan, wait
    /// a few seconds and ask Navidrome itself via the server.
    private func verifyInLibrary(rowAt index: Int, response: UploadResponse,
                                 client: APIClient) {
        guard response.scanTriggered else { return }
        let title = response.matchedTitle
            ?? response.savedAs
                .replacingOccurrences(of: " - ", with: " ")
                .components(separatedBy: ".")
                .dropLast()
                .joined(separator: ".")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard let result = try? await client.inLibrary(title: title,
                                                           artist: "")
            else { return }
            if result.found {
                rows[index].libraryNote = "In your Navidrome library \u{2713}"
            } else if result.configured {
                rows[index].libraryNote = "Saved \u{2014} Navidrome has not indexed it yet"
            }
        }
    }
}
