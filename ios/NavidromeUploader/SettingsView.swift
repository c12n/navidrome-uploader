//
//  SettingsView.swift
//  Navidrome Uploader
//
//  Tab 4: companion-service settings. The base URL is stored in
//  UserDefaults; the token is stored in the Keychain (via SettingsStore).
//  "Test connection" hits GET /health and reports the real result.
//

import SwiftUI

struct SettingsView: View {
    @Environment(SettingsStore.self) private var settings

    @State private var isTesting = false
    @State private var testResult: String?
    @State private var testSucceeded = false
    @State private var showSetupQR = false
    @State private var showSetupScanner = false
    @State private var setupNote: String?

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section("Server") {
                    LabeledContent("URL") {
                        TextField("https://upload.07051969.xyz", text: $settings.baseURLString)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Token") {
                        SecureField("Upload token", text: $settings.token)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }
                    Text(tokenStateText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    LabeledContent("TorBox") {
                        SecureField("API key", text: $settings.torboxKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Premiumize") {
                        SecureField("API key", text: $settings.premiumizeKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }
                } header: {
                    Text("Debrid services")
                } footer: {
                    Text(debridStateText)
                }

                Section {
                    Toggle("Clean up metadata \u{2014} URL downloads",
                           isOn: $settings.enrichURLs)
                    Toggle("Clean up metadata \u{2014} file uploads",
                           isOn: $settings.enrichFiles)
                    Toggle("Fetch & embed lyrics", isOn: $settings.embedLyrics)
                    Toggle("File into Artist / Album folders",
                           isOn: $settings.sortFolders)
                    Toggle("Skip songs already in the library",
                           isOn: $settings.skipDuplicates)
                } header: {
                    Text("Processing")
                } footer: {
                    Text("The server identifies each song (iTunes, then MusicBrainz + Cover Art Archive) and embeds proper title, artist, album and cover art into the audio file. Lyrics come from LRCLIB and are embedded into the file too, so they show in any player. File uploads are left untagged by default \u{2014} albums usually arrive already tagged.")
                }

                Section {
                    Button {
                        showSetupQR = true
                    } label: {
                        Label("Show my setup QR code", systemImage: "qrcode")
                    }
                    Button {
                        showSetupScanner = true
                    } label: {
                        Label("Scan a setup QR code", systemImage: "qrcode.viewfinder")
                    }
                    if let setupNote {
                        Text(setupNote)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Setup code")
                } footer: {
                    Text("Move this server + token to another device in one scan. The code contains your token \u{2014} treat it like a password.")
                }

                Section {
                    Button {
                        testConnection()
                    } label: {
                        HStack {
                            Spacer()
                            if isTesting {
                                ProgressView()
                                Text("Testing\u{2026}").padding(.leading, 6)
                            } else {
                                Text("Test connection").font(.headline)
                            }
                            Spacer()
                        }
                    }
                    .disabled(isTesting)

                    if let testResult {
                        Label(testResult,
                              systemImage: testSucceeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(testSucceeded ? .green : .red)
                    }
                }

                Section {
                    LabeledContent("Version", value: Self.versionString)
                } footer: {
                    Text("NaviUpload \u{2014} upload music to your Navidrome library from files or URLs.")
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showSetupQR) {
                ShowSetupCodeView()
            }
            .sheet(isPresented: $showSetupScanner) {
                ScanSetupCodeView { payload in
                    settings.baseURLString = payload.server
                    settings.token = payload.token
                    showSetupScanner = false
                    setupNote = "Setup applied from the scanned code \u{2014} run Test connection to confirm."
                }
            }
        }
    }

    /// What the Token field currently holds, without revealing it:
    /// enough for the user to sanity-check a paste (length + charset
    /// hint for the server's token format).
    private var tokenStateText: String {
        let token = settings.token.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.isEmpty {
            return "No token saved yet \u{2014} uploads will fail until you paste the server\u{2019}s UPLOAD_TOKEN here (32 characters, letters a\u{2013}f and digits, no dashes)."
        }
        return "Token saved (\(token.count) characters), stored in the Keychain and sent as the X-Upload-Token header. It must match the server\u{2019}s UPLOAD_TOKEN exactly."
    }

    /// Saved-state line for the Debrid section, lengths only.
    private var debridStateText: String {
        let tb = settings.torboxKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let pm = settings.premiumizeKey.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts: [String] = []
        if !tb.isEmpty { parts.append("TorBox key saved (\(tb.count) characters)") }
        if !pm.isEmpty { parts.append("Premiumize key saved (\(pm.count) characters)") }
        let state = parts.isEmpty ? "No keys saved." : parts.joined(separator: " \u{00B7} ")
        return "\(state) Optional: with a key saved, links on that service\u{2019}s supported hosters are fetched through your account. Keys live in the Keychain and are sent only to your own server, with URL downloads."
    }

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    private func testConnection() {
        isTesting = true
        testResult = nil
        let client = settings.client
        Task {
            do {
                let health = try await client.health()
                guard health.status == "ok" else {
                    testSucceeded = false
                    testResult = "Server answered with status \u{201C}\(health.status)\u{201D}."
                    isTesting = false
                    return
                }
                // /health is public: it proves reachability only. Probe
                // an authenticated endpoint so a missing/wrong token is
                // caught here instead of at the first upload.
                do {
                    try await client.verifyToken()
                    testSucceeded = true
                    testResult = "Connected \u{2014} token accepted, \(health.libraryFiles) files in the library."
                } catch let APIError.http(status, _) where status == 401 {
                    testSucceeded = false
                    testResult = "Server is reachable, but the token was rejected. Paste the server\u{2019}s UPLOAD_TOKEN into the Token field above."
                }
            } catch {
                testSucceeded = false
                testResult = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
            isTesting = false
        }
    }
}
