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
    // The delegate exists mainly for background-upload sessions:
    // it registers the background uploader with APIClient at launch
    // and receives the system's background-event completion handler.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

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
