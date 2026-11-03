//
//  ShareExtension.swift
//  NaviUpload Share Extension
//
//  "Send to NaviUpload" in the iOS share sheet: takes a shared web
//  URL (or text containing one) and posts it to the companion server,
//  exactly like the URL tab. The extension keeps its OWN copy of the
//  server URL + token (entered once here) — extensions cannot read
//  the main app's Keychain, and app groups are not reliable when
//  sideloaded.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

final class ShareExtensionController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        extractSharedURL { [weak self] url in
            guard let self else { return }
            let root = ShareRootView(
                sharedURL: url ?? "",
                onFinish: { [weak self] in
                    self?.extensionContext?.completeRequest(returningItems: nil)
                },
                onCancel: { [weak self] in
                    let error = NSError(
                        domain: "com.c12n.navidromeuploader.share",
                        code: 0, userInfo: nil)
                    self?.extensionContext?.cancelRequest(withError: error)
                })
            let host = UIHostingController(rootView: root)
            addChild(host)
            host.view.frame = view.bounds
            host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(host.view)
            host.didMove(toParent: self)
        }
    }

    /// Pull the first http(s) link out of whatever was shared: a URL
    /// attachment directly, or a URL inside shared text.
    private func extractSharedURL(completion: @escaping (String?) -> Void) {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let providers = items.flatMap { $0.attachments ?? [] }

        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.url.identifier) { value, _ in
                DispatchQueue.main.async {
                    if let url = value as? URL {
                        completion(url.absoluteString)
                    } else if let text = value as? String {
                        completion(Self.firstLink(in: text))
                    } else {
                        completion(nil)
                    }
                }
            }
            return
        }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { value, _ in
                DispatchQueue.main.async {
                    completion(Self.firstLink(in: (value as? String) ?? ""))
                }
            }
            return
        }
        completion(nil)
    }

    static func firstLink(in text: String) -> String? {
        text.components(separatedBy: .whitespacesAndNewlines)
            .first { $0.hasPrefix("http://") || $0.hasPrefix("https://") }
    }
}

// MARK: - UI

private struct ShareRootView: View {
    let sharedURL: String
    var onFinish: () -> Void
    var onCancel: () -> Void

    @State private var settings = SettingsStore()
    @State private var isWorking = false
    @State private var result: UploadResponse?
    @State private var errorMessage: String?

    private var tokenMissing: Bool {
        settings.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section("Link") {
                    if sharedURL.isEmpty {
                        Text("No link found in what you shared.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(sharedURL)
                            .font(.footnote)
                            .lineLimit(3)
                    }
                }

                if tokenMissing {
                    Section {
                        TextField("Server URL", text: $settings.baseURLString)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Upload token", text: $settings.token)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } header: {
                        Text("One-time setup")
                    } footer: {
                        Text("The share extension keeps its own copy of your setup. Paste the same token you use in the app.")
                    }
                }

                Section {
                    Button {
                        send()
                    } label: {
                        HStack {
                            Spacer()
                            if isWorking {
                                ProgressView()
                                Text("Sending\u{2026}").padding(.leading, 6)
                            } else {
                                Text("Send to Navidrome").font(.headline)
                            }
                            Spacer()
                        }
                    }
                    .disabled(isWorking || sharedURL.isEmpty || tokenMissing)
                }

                if let result {
                    Section("Done") {
                        Label("Saved to Navidrome", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        LabeledContent("File", value: result.savedAs)
                        if result.alsoSaved > 0 {
                            LabeledContent("Also saved",
                                           value: "\(result.alsoSaved) more file\(result.alsoSaved == 1 ? "" : "s")")
                        }
                        let notes = result.processingNotes
                        if !notes.isEmpty {
                            Text(notes.joined(separator: " \u{00B7} "))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Section {
                        Button("Done") { onFinish() }
                    }
                }

                if let errorMessage {
                    Section("Error") {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button("Cancel", role: .cancel) { onCancel() }
                }
            }
            .navigationTitle("NaviUpload")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func send() {
        isWorking = true
        errorMessage = nil
        let client = settings.client
        Task {
            do {
                result = try await client.uploadFromURL(
                    sharedURL,
                    enrich: settings.enrichURLs,
                    lyrics: settings.embedLyrics,
                    sort: settings.sortFolders)
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
            isWorking = false
        }
    }
}
