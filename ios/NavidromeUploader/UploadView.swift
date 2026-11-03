//
//  UploadView.swift
//  Navidrome Uploader
//
//  Tab 1: pick audio files — or a whole folder (e.g. an album) — from
//  Files and upload them to the companion service one by one, with
//  live send progress and a clear success / error summary.
//
//  v1.0.1: multiple selection + folder selection. A picked folder is
//  expanded recursively to the audio files inside it, in path order,
//  so an album uploads in track order.
//

import SwiftUI
import UniformTypeIdentifiers

struct UploadView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(HistoryStore.self) private var history

    @State private var showImporter = false
    @State private var isUploading = false
    @State private var progress: Double = 0
    @State private var statusLine: String?
    @State private var summary: String?
    @State private var detailLine: String?
    @State private var summaryIsError = false
    @State private var errorMessage: String?

    /// Audio types the picker offers: the built-in audio UTTypes plus the
    /// extensions from the spec that have no system constant. Folders are
    /// included so a whole album folder can be picked at once.
    private var pickerTypes: [UTType] {
        var types: [UTType] = [.audio, .mp3, .mpeg4Audio, .wav, .aiff, .folder]
        for ext in ["flac", "ogg", "oga", "opus", "aac", "m4a"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        return types
    }

    private static let audioExtensions: Set<String> = [
        "mp3", "m4a", "flac", "wav", "ogg", "oga", "opus", "aac", "aif", "aiff",
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "music.note.list")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)

                Text("Send audio files \u{2014} or a whole album folder \u{2014} straight to your Navidrome library.")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

                Button {
                    showImporter = true
                } label: {
                    Label("Choose audio files or a folder", systemImage: "folder")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal)
                .disabled(isUploading)

                if isUploading {
                    VStack(spacing: 8) {
                        ProgressView(value: progress)
                            .padding(.horizontal, 40)
                        if let statusLine {
                            Text(statusLine)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .padding(.horizontal)
                        }
                    }
                } else if let summary {
                    VStack(spacing: 6) {
                        Label(summary,
                              systemImage: summaryIsError
                                  ? "exclamationmark.triangle.fill"
                                  : "checkmark.circle.fill")
                            .font(.headline)
                            .foregroundStyle(summaryIsError ? .orange : .green)
                            .multilineTextAlignment(.center)
                        if let detailLine {
                            Text(detailLine)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding(.horizontal)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Spacer()
            }
            .navigationTitle("Upload")
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: pickerTypes,
                          allowsMultipleSelection: true) { outcome in
                switch outcome {
                case .success(let urls):
                    startQueue(urls)
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    // MARK: Selection expansion

    /// Expands picked URLs into a flat, path-ordered list of audio
    /// files: folders are walked recursively, plain files are kept when
    /// their extension is a supported audio type.
    private func expand(_ urls: [URL]) -> [URL] {
        var files: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                guard let walker = fm.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]) else { continue }
                for case let child as URL in walker {
                    if Self.audioExtensions.contains(child.pathExtension.lowercased()) {
                        files.append(child)
                    }
                }
            } else if Self.audioExtensions.contains(url.pathExtension.lowercased()) {
                files.append(url)
            }
        }
        return files.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }

    // MARK: Upload queue

    private func startQueue(_ picked: [URL]) {
        summary = nil
        detailLine = nil
        errorMessage = nil
        summaryIsError = false

        // Hold security scope on the picked items for the whole queue —
        // files inside a picked folder are covered by the folder's scope.
        let scoped = picked.filter { $0.startAccessingSecurityScopedResource() }

        let files = expand(picked)
        guard !files.isEmpty else {
            scoped.forEach { $0.stopAccessingSecurityScopedResource() }
            errorMessage = "No audio files in that selection. Pick audio files, or a folder that contains them."
            return
        }

        isUploading = true
        progress = 0
        let client = settings.client
        Task {
            defer {
                scoped.forEach { $0.stopAccessingSecurityScopedResource() }
                isUploading = false
                statusLine = nil
            }
            var okCount = 0
            var okBytes = 0
            var lastResponse: UploadResponse?
            var failures: [(name: String, message: String)] = []

            for (index, file) in files.enumerated() {
                statusLine = files.count > 1
                    ? "File \(index + 1) of \(files.count) \u{00B7} \(file.lastPathComponent)"
                    : "Uploading \(file.lastPathComponent)"
                progress = 0
                do {
                    let response = try await client.uploadFile(fileURL: file) { fraction in
                        progress = fraction
                    }
                    okCount += 1
                    okBytes += response.size
                    lastResponse = response
                    history.add(name: file.lastPathComponent, source: .file, response: response)
                } catch {
                    failures.append((
                        name: file.lastPathComponent,
                        message: (error as? LocalizedError)?.errorDescription
                            ?? error.localizedDescription))
                }
            }

            if failures.isEmpty {
                summaryIsError = false
                if files.count == 1, let response = lastResponse {
                    summary = "Uploaded"
                    detailLine = "\(response.savedAs)\n\(ByteCountFormatter.string(fromByteCount: Int64(response.size), countStyle: .file)) \u{00B7} \(response.scanTriggered ? "Library scan triggered" : "Saved \u{2014} scan not triggered")"
                } else {
                    summary = "Uploaded \(okCount) files"
                    detailLine = ByteCountFormatter.string(fromByteCount: Int64(okBytes), countStyle: .file)
                        + " \u{00B7} in your library now"
                }
            } else if okCount > 0 {
                summaryIsError = true
                summary = "Uploaded \(okCount) of \(files.count) \u{2014} \(failures.count) failed"
                detailLine = failures.first.map { "\($0.name): \($0.message)" }
            } else {
                summary = nil
                errorMessage = failures.first.map {
                    files.count > 1 ? "\($0.name): \($0.message)" : $0.message
                } ?? "Upload failed."
            }
        }
    }
}
