//
//  NavidromeUploaderApp.swift
//  Navidrome Uploader
//
//  App entry point. Creates the shared observable stores (settings +
//  upload history) and injects them into the environment.
//

import SwiftUI

@main
struct NavidromeUploaderApp: App {
    @State private var settings = SettingsStore()
    @State private var history = HistoryStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(settings)
                .environment(history)
        }
    }
}
