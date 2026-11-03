//
//  URLUploadView.swift
//  Navidrome Uploader
//
//  Tab 2: paste or type a URL and have the server download it into the
//  Navidrome library. Direct audio links are fetched as-is; YouTube and
//  other page links are handled server-side via yt-dlp.
//

import SwiftUI
import UIKit

struct URLUploadView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(HistoryStore.self) private var history

    @State private var urlText = ""
    @State private var isWorking = false
    @State private var result: UploadResponse?
    @State private var errorMessage: String?

    private var trimmedURL: String {
        urlText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Link") {
                    TextField("https://\u{2026}", text: $urlText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        if let pasted = UIPasteboard.general.string {
                            urlText = pasted
                        }
                    } label: {
                        Label("Paste", systemImage: "doc.on.clipboard")
                    }
                    .disabled(isWorking)
                }

                Section {
                    Button {
                        startDownload()
                    } label: {
                        HStack {
                            Spacer()
                            if isWorking {
                                ProgressView()
                                Text("Downloading\u{2026}").padding(.leading, 6)
                            } else {
                                Text("Download to Navidrome").font(.headline)
                            }
                            Spacer()
                        }
                    }
                    .disabled(isWorking || trimmedURL.isEmpty)
                }

                Section {
                    Text("Direct audio links (mp3, m4a, flac, wav, ogg, opus, aac) are fetched as-is. Links on supported file hosters are fetched through your TorBox or Premiumize account when the server has a key for one. YouTube and other page links are handled on the server with yt-dlp.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let result {
                    Section("Done") {
                        Label("Saved to Navidrome", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        LabeledContent("File", value: result.savedAs)
                        LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: Int64(result.size), countStyle: .file))
                        LabeledContent("Library scan", value: result.scanTriggered ? "Triggered" : "Not triggered")
                    }
                }

                if let errorMessage {
                    Section("Error") {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("URL")
        }
    }

    private func startDownload() {
        result = nil
        errorMessage = nil
        isWorking = true
        let client = settings.client
        let target = trimmedURL
        Task {
            do {
                let response = try await client.uploadFromURL(target)
                result = response
                history.add(name: target, source: .url, response: response)
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
            isWorking = false
        }
    }
}
