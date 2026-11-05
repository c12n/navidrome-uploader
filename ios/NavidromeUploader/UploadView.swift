//
//  UploadView.swift
//  Navidrome Uploader
//
//  Tab 1: pick audio files — or a whole folder (an album) — and send
//  them to the Navidrome library as a managed queue:
//
//    * picked folders expand recursively, in track order
//    * duplicates are checked against the library first (Settings)
//      and skipped with a clear marker
//    * the queue can be paused / resumed, and failed files retry
//      (once automatically, then via "Retry failed")
//    * file uploads run on a background URLSession, so they keep
//      going when the phone locks; a notification lands when the
//      queue finishes in the background
//    * the library card up top shows live stats + a refresh button
//

import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

private struct QueueItem: Identifiable {
    enum State: Equatable {
        case pending, uploading, done, failed(String), skippedDuplicate
    }

    let id = UUID()
    let url: URL
    var size: Int = 0
    var state: State = .pending
    var progress: Double = 0
    var attempts: Int = 0
    var possibleDuplicate = false
    var response: UploadResponse?

    var name: String { url.lastPathComponent }
}

struct UploadView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(HistoryStore.self) private var history

    @State private var showImporter = false
    @State private var queue: [QueueItem] = []
    @State private var scopedRoots: [URL] = []
    @State private var isRunning = false
    @State private var isPaused = false
    @State private var note: String?
    @State private var noteIsError = false
    @State private var cardReload = 0
    @State private var availableUpdate: AvailableUpdate?
    @State private var dismissedUpdateVersion: String? =
        UserDefaults.standard.string(forKey: "update.dismissedVersion")

    private var pickerTypes: [UTType] {
        var types: [UTType] = [.audio, .mp3, .mpeg4Audio, .wav, .aiff, .folder]
        for ext in ["flac", "ogg", "oga", "opus", "aac", "m4a"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        return types
    }

    private static let audioExtensions: Set<String> = [
        "mp3", "m4a", "flac", "wav", "ogg", "oga", "opus", "aac", "aif", "aiff",
    ]

    private var pendingCount: Int { queue.filter { $0.state == .pending }.count }
    private var failedItems: [QueueItem] { queue.filter {
        if case .failed = $0.state { return true }
        return false
    } }
    private var doneCount: Int { queue.filter { $0.state == .done }.count }

    var body: some View {
        NavigationStack {
            List {
                if let update = availableUpdate,
                   update.version != dismissedUpdateVersion {
                    Section {
                        HStack(spacing: 10) {
                            Image(systemName: "arrow.down.circle.fill")
                                .foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("NaviUpload \(update.version) is available")
                                    .font(.subheadline.bold())
                                Text("Get the new build from the GitHub release page.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Link("View", destination: update.pageURL)
                                .font(.subheadline.bold())
                            Button {
                                dismissedUpdateVersion = update.version
                                UserDefaults.standard.set(
                                    update.version,
                                    forKey: "update.dismissedVersion")
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.footnote.bold())
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section {
                    LibraryCardView(reloadToken: cardReload)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                Section {
                    Button {
                        showImporter = true
                    } label: {
                        Label(queue.isEmpty
                              ? "Choose audio files or a folder"
                              : "Add more files or a folder",
                              systemImage: "folder")
                            .font(.headline)
                    }
                    .disabled(isRunning)
                } footer: {
                    Text("A picked folder (for example an album) expands to every audio file inside it, in track order. Uploads start automatically as soon as you've picked, and keep going in the background if you lock the phone.")
                }

                if let note {
                    Section {
                        Label(note,
                              systemImage: noteIsError
                                  ? "exclamationmark.triangle.fill"
                                  : "checkmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(noteIsError ? .orange : .green)
                    }
                }

                if !queue.isEmpty {
                    Section {
                        if isRunning {
                            Button {
                                isPaused.toggle()
                            } label: {
                                Label(isPaused ? "Resume" : "Pause",
                                      systemImage: isPaused ? "play.fill" : "pause.fill")
                            }
                        } else if pendingCount > 0 {
                            Button {
                                runQueue()
                            } label: {
                                Label("Upload \(pendingCount) file\(pendingCount == 1 ? "" : "s")",
                                      systemImage: "arrow.up.circle.fill")
                                    .font(.headline)
                            }
                        }
                        if !failedItems.isEmpty && !isRunning {
                            Button {
                                requeueFailed()
                            } label: {
                                Label("Retry \(failedItems.count) failed",
                                      systemImage: "arrow.counterclockwise")
                            }
                        }
                        if !isRunning {
                            Button(role: .destructive) {
                                clearQueue()
                            } label: {
                                Label("Clear list", systemImage: "trash")
                            }
                        }
                    }

                    Section("Files") {
                        ForEach(queue) { item in
                            queueRow(item)
                        }
                    }
                }
            }
            .navigationTitle("Upload")
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: pickerTypes,
                          allowsMultipleSelection: true) { outcome in
                switch outcome {
                case .success(let urls):
                    Task { await prepareQueue(picked: urls) }
                case .failure(let error):
                    note = error.localizedDescription
                    noteIsError = true
                }
            }
            .task {
                // Ask once so a background-finished queue can notify.
                UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound]) { _, _ in }
            }
            .task {
                // Update banner: GitHub's latest release vs this build
                // (the checker itself throttles to every 6 hours).
                availableUpdate = await UpdateChecker.availableUpdate()
            }
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func queueRow(_ item: QueueItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.name)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                Spacer()
                stateBadge(item)
            }
            switch item.state {
            case .uploading:
                ProgressView(value: item.progress)
            case .failed(let message):
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            case .done:
                if let response = item.response {
                    let notes = response.processingNotes
                    Text(notes.isEmpty
                         ? "In the library"
                         : notes.joined(separator: " \u{00B7} "))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            case .skippedDuplicate:
                Text("Already in your library \u{2014} skipped")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .pending:
                if item.possibleDuplicate {
                    Text("A file with this size is already in the library \u{2014} will upload anyway")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                } else if item.size > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func stateBadge(_ item: QueueItem) -> some View {
        switch item.state {
        case .pending:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .uploading:
            Image(systemName: "arrow.up.circle").foregroundStyle(.tint)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        case .skippedDuplicate:
            Image(systemName: "equal.circle").foregroundStyle(.secondary)
        }
    }

    // MARK: Selection + duplicate check

    /// Expands picked URLs into a flat, path-ordered list of audio
    /// files: folders are walked recursively, plain files are kept
    /// when their extension is a supported audio type.
    private func expand(_ urls: [URL]) -> [URL] {
        var files: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                guard let walker = fm.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]) else { continue }
                for case let child as URL in walker {
                    if Self.audioExtensions.contains(child.pathExtension.lowercased()) {
                        files.append(child)
                    }
                }
            } else if Self.audioExtensions.contains(url.pathExtension.lowercased()) {
                files.append(url)
            }
        }
        return files.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }

    private func prepareQueue(picked: [URL]) async {
        note = nil
        noteIsError = false
        // Hold security scope on the picked roots for as long as the
        // queue exists (files inside a folder are covered by its scope).
        let alreadyQueued = Set(queue.map { $0.url })
        for root in picked where !scopedRoots.contains(root) {
            if root.startAccessingSecurityScopedResource() {
                scopedRoots.append(root)
            }
        }
        var added = 0
        for file in expand(picked) where !alreadyQueued.contains(file) {
            var item = QueueItem(url: file)
            item.size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?
                .fileSize ?? 0
            queue.append(item)
            added += 1
        }
        guard added > 0 else {
            note = "No new audio files in that selection."
            noteIsError = true
            return
        }

        // Duplicate check against the server's library, when enabled.
        if settings.skipDuplicates,
           !settings.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let pending = queue.filter { $0.state == .pending }
            if !pending.isEmpty,
               let results = try? await settings.client.checkDuplicates(
                   items: pending.map { (name: $0.name, size: $0.size) }),
               results.count == pending.count {
                for (item, result) in zip(pending, results) {
                    guard let index = queue.firstIndex(where: { $0.id == item.id })
                    else { continue }
                    if result.exists {
                        queue[index].state = .skippedDuplicate
                    } else if result.sameSize {
                        queue[index].possibleDuplicate = true
                    }
                }
            }
        }

        // Start automatically (0.5.1): picking files IS the
        // instruction to upload them — no second tap on an
        // "Upload N files" button. The button stays for resuming a
        // prepared queue that never ran.
        if pendingCount > 0 && !isRunning {
            runQueue()
        }

        let skipped = queue.filter { $0.state == .skippedDuplicate }.count
        if skipped > 0 {
            note = "\(skipped) file\(skipped == 1 ? " is" : "s are") already in your library and will be skipped."
            noteIsError = false
        }
    }

    // MARK: Running the queue

    private func requeueFailed() {
        for index in queue.indices {
            if case .failed = queue[index].state {
                queue[index].state = .pending
                queue[index].attempts = 0
                queue[index].progress = 0
            }
        }
        runQueue()
    }

    private func clearQueue() {
        queue.removeAll()
        scopedRoots.forEach { $0.stopAccessingSecurityScopedResource() }
        scopedRoots.removeAll()
        note = nil
    }

    private func runQueue() {
        guard !isRunning else { return }
        isRunning = true
        isPaused = false
        note = nil
        let client = settings.client
        let enrich = settings.enrichFiles
        let lyrics = settings.embedLyrics
        let sort = settings.sortFolders

        Task { @MainActor in
            // Two passes: the second pass retries fresh failures once.
            for pass in 0...1 {
                var index = 0
                while index < queue.count {
                    while isPaused {
                        try? await Task.sleep(for: .milliseconds(300))
                    }
                    if queue[index].state == .pending {
                        queue[index].state = .uploading
                        queue[index].progress = 0
                        queue[index].attempts += 1
                        let itemID = queue[index].id
                        let fileURL = queue[index].url
                        do {
                            let response = try await client.uploadFile(
                                fileURL: fileURL,
                                enrich: enrich, lyrics: lyrics, sort: sort
                            ) { fraction in
                                if let i = queue.firstIndex(where: { $0.id == itemID }) {
                                    queue[i].progress = fraction
                                }
                            }
                            if let i = queue.firstIndex(where: { $0.id == itemID }) {
                                queue[i].state = .done
                                queue[i].response = response
                            }
                            history.add(name: fileURL.lastPathComponent,
                                        source: .file, response: response)
                        } catch {
                            if let i = queue.firstIndex(where: { $0.id == itemID }) {
                                queue[i].state = .failed(
                                    (error as? LocalizedError)?.errorDescription
                                        ?? error.localizedDescription)
                            }
                        }
                    }
                    index += 1
                }
                // Second pass only if something failed on the first.
                if pass == 0 {
                    var retried = false
                    for i in queue.indices {
                        if case .failed = queue[i].state, queue[i].attempts < 2 {
                            queue[i].state = .pending
                            retried = true
                        }
                    }
                    if !retried { break }
                }
            }

            isRunning = false
            cardReload += 1
            let done = doneCount
            let failed = failedItems.count
            if failed == 0, done > 0 {
                note = "Uploaded \(done) file\(done == 1 ? "" : "s") to your library."
                noteIsError = false
            } else if done > 0 {
                note = "Uploaded \(done) \u{2014} \(failed) failed. Use Retry to try them again."
                noteIsError = true
            } else if failed > 0 {
                note = "\(failed) upload\(failed == 1 ? "" : "s") failed."
                noteIsError = true
            }
            if done > 0 {
                notifyIfBackgrounded(
                    title: "NaviUpload finished",
                    body: failed == 0
                        ? "\(done) song\(done == 1 ? "" : "s") added to your Navidrome library."
                        : "\(done) added, \(failed) failed.")
            }
        }
    }

    private func notifyIfBackgrounded(title: String, body: String) {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString,
                                  content: content, trigger: nil))
    }
}
