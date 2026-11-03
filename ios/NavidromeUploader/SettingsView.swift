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
                    Text("The token is stored in the Keychain and sent as the X-Upload-Token header.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
                    LabeledContent("Version", value: "1.0.0 (1)")
                } footer: {
                    Text("NaviUpload \u{2014} upload music to your Navidrome library from files or URLs.")
                }
            }
            .navigationTitle("Settings")
        }
    }

    private func testConnection() {
        isTesting = true
        testResult = nil
        let client = settings.client
        Task {
            do {
                let health = try await client.health()
                testSucceeded = health.status == "ok"
                testResult = "Connected \u{2014} status \u{201C}\(health.status)\u{201D}, \(health.libraryFiles) files in the library."
            } catch {
                testSucceeded = false
                testResult = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
            isTesting = false
        }
    }
}
