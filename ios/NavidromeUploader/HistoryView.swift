//
//  HistoryView.swift
//  Navidrome Uploader
//
//  Tab 3: completed uploads, persisted on-device (UserDefaults via
//  HistoryStore). Shows name, source, date and scan status per entry.
//

import SwiftUI

struct HistoryView: View {
    @Environment(HistoryStore.self) private var history
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        NavigationStack {
            Group {
                if history.items.isEmpty {
                    ContentUnavailableView(
                        "No uploads yet",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Files and URLs you send to Navidrome will appear here.")
                    )
                } else {
                    List {
                        ForEach(history.items) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.name)
                                    .font(.headline)
                                    .lineLimit(2)
                                HStack(spacing: 8) {
                                    Label(item.source.rawValue,
                                          systemImage: item.source == .file ? "doc" : "link")
                                    Text("\u{00B7}")
                                    Text(item.date, format: .dateTime.month().day().hour().minute())
                                    if item.fromServer {
                                        Text("Server")
                                            .font(.caption2.bold())
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 1)
                                            .background(.thinMaterial, in: Capsule())
                                    }
                                }
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                if !item.folder.isEmpty {
                                    Text(item.folder)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                HStack(spacing: 8) {
                                    if item.size > 0 {
                                        Text(ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file))
                                    }
                                    Text(item.scanTriggered ? "Scan triggered" : "Scan not triggered")
                                }
                                .font(.footnote)
                                .foregroundStyle(item.scanTriggered ? .green : .secondary)
                            }
                            .padding(.vertical, 2)
                        }
                        .onDelete { history.delete(at: $0) }
                    }
                }
            }
            .navigationTitle("History")
            .task {
                // Merge the server's own log so uploads made from the
                // Windows app (or another device) show up here too.
                if let entries = try? await settings.client.recentUploads() {
                    history.mergeServer(entries)
                }
            }
            .toolbar {
                if !history.items.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Clear all", role: .destructive) { history.clear() }
                    }
                }
            }
        }
    }
}
