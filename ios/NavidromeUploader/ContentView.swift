//
//  ContentView.swift
//  Navidrome Uploader
//
//  Root view: a four-tab TabView — Upload, URL, History, Settings.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            UploadView()
                .tabItem { Label("Upload", systemImage: "arrow.up.doc") }

            URLUploadView()
                .tabItem { Label("URL", systemImage: "link") }

            HistoryView()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}
