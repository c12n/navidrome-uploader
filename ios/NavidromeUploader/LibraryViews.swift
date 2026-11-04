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

// MARK: - Duplicate finder

/// Songs that exist more than once in the library (server-side
/// GET /duplicates), with per-copy delete via POST /delete. The
/// biggest copy of each song is marked as the keeper; deleting is
/// always confirmed first and takes effect on the server at once.
struct DuplicateFinderView: View {
    @Environment(SettingsStore.self) private var settings

    @State private var result: DuplicatesResponse?
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var pendingDelete: [DuplicateFile] = []
    @State private var showConfirm = false
    @State private var isDeleting = false
    @State private var note: String?

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Scanning the library\u{2026}")
            } else if let errorText {
                ContentUnavailableView(
                    "Could not scan",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorText))
            } else if let result, result.groups.isEmpty {
                ContentUnavailableView(
                    "No duplicates",
                    systemImage: "checkmark.circle",
                    description: Text(
                        "Every song in your library exists exactly once."))
            } else if let result {
                List {
                    Section {
                        Text("\(result.groupCount) songs are duplicated "
                             + "(\(result.fileCount) files) \u{00B7} "
                             + ByteCountFormatter.string(
                                fromByteCount: Int64(result.wastedBytes),
                                countStyle: .file)
                             + " wasted")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if let note {
                            Text(note).font(.footnote)
                        }
                    }
                    ForEach(result.groups, id: \.files.first?.file) { group in
                        Section {
                            ForEach(
                                Array(group.files.enumerated()),
                                id: \.element.file) { index, file in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(file.file)
                                            .font(.footnote)
                                            .lineLimit(2)
                                        Text(ByteCountFormatter.string(
                                            fromByteCount: Int64(file.size),
                                            countStyle: .file))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if index == 0 {
                                        Text("Keep")
                                            .font(.caption.bold())
                                            .foregroundStyle(.green)
                                    } else {
                                        Button("Delete", role: .destructive) {
                                            pendingDelete = [file]
                                            showConfirm = true
                                        }
                                        .disabled(isDeleting)
                                    }
                                }
                            }
                            if group.files.count > 2 {
                                Button("Delete extra copies", role: .destructive) {
                                    pendingDelete = Array(group.files.dropFirst())
                                    showConfirm = true
                                }
                                .disabled(isDeleting)
                            }
                        } header: {
                            Text(group.artist.isEmpty
                                 ? group.title
                                 : "\(group.artist) \u{2014} \(group.title)")
                        }
                    }
                }
            }
        }
        .navigationTitle("Duplicate songs")
        .task { await load() }
        .confirmationDialog(
            pendingDelete.count == 1
                ? "Delete this copy from the library?"
                : "Delete \(pendingDelete.count) copies from the library?",
            isPresented: $showConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await deletePending() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the file from your server for good. "
                 + "The biggest copy of each song is kept.")
        }
    }

    private func load() async {
        isLoading = true
        errorText = nil
        do {
            result = try await settings.client.duplicates()
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
        isLoading = false
    }

    private func deletePending() async {
        let files = pendingDelete.map(\.file)
        guard !files.isEmpty else { return }
        isDeleting = true
        do {
            let response = try await settings.client.deleteFiles(files)
            note = response.errors.isEmpty
                ? "Deleted \(response.deleted.count) file(s)."
                : "Deleted \(response.deleted.count); "
                    + "\(response.errors.count) could not be deleted."
            await load()
        } catch {
            note = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
        isDeleting = false
    }
}
