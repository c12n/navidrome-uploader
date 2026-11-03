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
                                }
                                .font(.footnote)
                                .foregroundStyle(.secondary)
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
