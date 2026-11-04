//
//  HistoryView.swift
//  Navidrome Uploader
//
//  Tab 3: completed uploads, persisted on-device (UserDefaults via
//  HistoryStore). Shows name, source, date and scan status per entry.
//

import SwiftUI

struct HistoryView: View {
    @Environment(HistoryStore.self) private var history
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        NavigationStack {
            Group {
                if history.items.isEmpty {
                    ContentUnavailableView(
                        "No uploads yet",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Files and URLs you send to Navidrome will appear here.")
                    )
                } else {
                    List {
                        ForEach(history.items) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.name)
                                    .font(.headline)
                                    .lineLimit(2)
                                HStack(spacing: 8) {
                                    Label(item.source.rawValue,
                                          systemImage: item.source == .file ? "doc" : "link")
                                    Text("\u{00B7}")
                                    Text(item.date, format: .dateTime.month().day().hour().minute())
                                    if item.fromServer {
                                        Text("Server")
                                            .font(.caption2.bold())
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 1)
                                            .background(.thinMaterial, in: Capsule())
                                    }
                                }
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                if !item.folder.isEmpty {
                                    Text(item.folder)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                HStack(spacing: 8) {
                                    if item.size > 0 {
                                        Text(ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file))
                                    }
                                    Text(item.scanTriggered ? "Scan triggered" : "Scan not triggered")
                                }
                                .font(.footnote)
                                .foregroundStyle(item.scanTriggered ? .green : .secondary)
                                if !item.failedTracks.isEmpty {
                                    FailedTracksRow(item: item)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .onDelete { history.delete(at: $0) }
                    }
                }
            }
            .navigationTitle("History")
            .task {
                // Merge the server's own log so uploads made from the
                // Windows app (or another device) show up here too.
                if let entries = try? await settings.client.recentUploads() {
                    history.mergeServer(entries)
                }
            }
            .toolbar {
                if !history.items.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Clear all", role: .destructive) { history.clear() }
                    }
                }
            }
        }
    }
}

/// The failed tracks of a URL batch, with a one-tap retry that asks
/// the server to fetch just those tracks again (POST /tracks).
private struct FailedTracksRow: View {
    let item: HistoryItem

    @Environment(SettingsStore.self) private var settings
    @Environment(HistoryStore.self) private var history

    @State private var isRetrying = false
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(item.failedTracks.count) track(s) didn\u{2019}t download:")
                .font(.footnote)
                .foregroundStyle(.orange)
            ForEach(item.failedTracks.prefix(5), id: \.self) { track in
                Text(track)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if item.failedTracks.count > 5 {
                Text("\u{2026}and \(item.failedTracks.count - 5) more")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button {
                    Task { await retry() }
                } label: {
                    if isRetrying {
                        ProgressView()
                        Text("Retrying\u{2026}")
                    } else {
                        Label("Retry failed tracks",
                              systemImage: "arrow.clockwise")
                    }
                }
                .font(.footnote.bold())
                .disabled(isRetrying)
                if let note {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.top, 2)
    }

    private func retry() async {
        isRetrying = true
        note = nil
        do {
            let response = try await settings.client.retryTracks(
                item.failedTracks,
                enrich: settings.enrichURLs,
                lyrics: settings.embedLyrics,
                sort: settings.sortFolders)
            history.add(name: response.savedAs, source: .url,
                        response: response,
                        failedTracks: response.failedTracks,
                        sourceURL: item.sourceURL)
            for extra in response.files.dropFirst() {
                history.add(name: extra.savedAs, source: .url,
                            response: extra)
            }
            // The fresh entry above carries whatever is still
            // failing; this entry's retry offer is spent.
            history.setFailedTracks(id: item.id, tracks: [])
            note = response.failedTracks.isEmpty
                ? "All caught up."
                : "\(response.failedTracks.count) still failing."
        } catch {
            note = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
        isRetrying = false
    }
}
