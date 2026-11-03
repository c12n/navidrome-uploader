//
//  LibraryViews.swift
//  Navidrome Uploader
//
//  The library card: live statistics from the server (songs in the
//  library right now, songs NaviUpload has added all-time) plus the
//  manual "Refresh library" button (POST /scan) that asks Navidrome
//  to rescan immediately.
//

import SwiftUI

struct LibraryCardView: View {
    @Environment(SettingsStore.self) private var settings

    /// Bump from outside (e.g. after an upload finishes) to reload.
    var reloadToken: Int = 0

    @State private var stats: StatsResponse?
    @State private var loadFailed = false
    @State private var isRefreshing = false
    @State private var refreshNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Your library", systemImage: "music.note.house.fill")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await refresh() }
                } label: {
                    if isRefreshing {
                        ProgressView()
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .font(.subheadline.bold())
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isRefreshing)
            }

            if let stats {
                HStack(spacing: 28) {
                    statBlock(value: stats.libraryFiles, label: "songs in the library")
                    statBlock(value: stats.uploadedTotal, label: "uploaded via NaviUpload")
                    if stats.uploadedBytes > 0 {
                        statBlock(text: ByteCountFormatter.string(
                            fromByteCount: Int64(stats.uploadedBytes),
                            countStyle: .file), label: "added in total")
                    }
                }
            } else if loadFailed {
                Text("Could not load library stats \u{2014} check the server in Settings.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("Loading library stats\u{2026}")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let refreshNote {
                Text(refreshNote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .task { await load() }
        .onChange(of: reloadToken) { _, _ in Task { await load() } }
    }

    private func statBlock(value: Int, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(.title3.bold())
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func statBlock(text: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text)
                .font(.title3.bold())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func load() async {
        do {
            stats = try await settings.client.stats()
            loadFailed = false
        } catch {
            loadFailed = true
        }
    }

    /// The manual refresh button: POST /scan, explain the outcome in
    /// plain words, then reload the counts (a triggered scan takes a
    /// moment to show up in them).
    private func refresh() async {
        isRefreshing = true
        refreshNote = nil
        do {
            let result = try await settings.client.scanLibrary()
            if result.triggered {
                refreshNote = "Refresh triggered \u{2014} new songs appear in Navidrome within seconds."
            } else if result.configured {
                refreshNote = "Navidrome did not accept the refresh this time. Try again in a moment."
            } else {
                refreshNote = "Instant refresh is not set up on the server yet (it needs the Navidrome login in the server config). Uploads still appear after Navidrome\u{2019}s own scheduled scan."
            }
            try? await Task.sleep(for: .seconds(2))
            await load()
        } catch {
            refreshNote = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
        isRefreshing = false
    }
}
