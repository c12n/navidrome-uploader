//
//  UploadView.swift
//  Navidrome Uploader
//
//  Tab 1: pick an audio file from Files and upload it to the companion
//  service, with live send progress and a clear success / error state.
//

import SwiftUI
import UniformTypeIdentifiers

struct UploadView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(HistoryStore.self) private var history

    @State private var showImporter = false
    @State private var isUploading = false
    @State private var progress: Double = 0
    @State private var selectedName: String?
    @State private var result: UploadResponse?
    @State private var errorMessage: String?

    /// Audio types the picker offers: the built-in audio UTTypes plus the
    /// extensions from the spec that have no system constant.
    private var audioTypes: [UTType] {
        var types: [UTType] = [.audio, .mp3, .mpeg4Audio, .wav, .aiff]
        for ext in ["flac", "ogg", "oga", "opus", "aac", "m4a"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        return types
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "music.note.list")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)

                Text("Send an audio file straight to your Navidrome library.")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

                Button {
                    showImporter = true
                } label: {
                    Label("Choose audio file", systemImage: "folder")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal)
                .disabled(isUploading)

                if let selectedName {
                    Text(selectedName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if isUploading {
                    VStack(spacing: 8) {
                        ProgressView(value: progress)
                            .padding(.horizontal, 40)
                        Text("Uploading\u{2026} \(Int(progress * 100))%")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else if let result {
                    VStack(spacing: 6) {
                        Label("Uploaded", systemImage: "checkmark.circle.fill")
                            .font(.headline)
                            .foregroundStyle(.green)
                        Text(result.savedAs)
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                        Text("\(ByteCountFormatter.string(fromByteCount: Int64(result.size), countStyle: .file)) \u{00B7} \(result.scanTriggered ? "Library scan triggered" : "Saved \u{2014} scan not triggered")")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
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
                          allowedContentTypes: audioTypes,
                          allowsMultipleSelection: false) { outcome in
                switch outcome {
                case .success(let urls):
                    if let url = urls.first { startUpload(url) }
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func startUpload(_ url: URL) {
        selectedName = url.lastPathComponent
        result = nil
        errorMessage = nil
        progress = 0
        isUploading = true
        let client = settings.client
        Task {
            do {
                let response = try await client.uploadFile(fileURL: url) { fraction in
                    progress = fraction
                }
                result = response
                history.add(name: url.lastPathComponent, source: .file, response: response)
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
            isUploading = false
        }
    }
}
