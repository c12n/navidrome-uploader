//
//  BackgroundUploads.swift
//  Navidrome Uploader
//
//  Background-session file uploads: a URLSession on a background
//  configuration keeps uploads running when the app is suspended or
//  the phone locks. The app delegate registers the session's upload
//  function with APIClient at launch; the share extension never does,
//  so it keeps using the inline session.
//
//  Also holds the UIApplicationDelegate that receives the system's
//  background-session completion handler.
//

import Foundation
import UIKit

final class BackgroundUploadManager: NSObject, URLSessionDelegate,
                                     URLSessionDataDelegate,
                                     URLSessionTaskDelegate {
    static let shared = BackgroundUploadManager()

    static let sessionIdentifier = "com.c12n.navidromeuploader.background-uploads"

    private struct Pending {
        var continuation: CheckedContinuation<(Data, URLResponse), Error>
        var progress: @MainActor (Double) -> Void
        var received = Data()
        var response: URLResponse?
    }

    private var pending: [Int: Pending] = [:]
    private let lock = NSLock()

    private(set) lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(
            withIdentifier: Self.sessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        return URLSession(configuration: config, delegate: self,
                          delegateQueue: nil)
    }()

    /// Hand APIClient the background upload function. Called once from
    /// the app delegate at launch.
    static func register() {
        APIClient.backgroundUploadFunction = { request, bodyFile, progress in
            try await BackgroundUploadManager.shared.upload(
                request: request, bodyFile: bodyFile, progress: progress)
        }
    }

    func upload(request: URLRequest, bodyFile: URL,
                progress: @escaping @MainActor (Double) -> Void)
        async throws -> (Data, URLResponse) {
        let session = self.session
        return try await withCheckedThrowingContinuation { continuation in
            let task = session.uploadTask(with: request, fromFile: bodyFile)
            lock.lock()
            pending[task.taskIdentifier] = Pending(
                continuation: continuation, progress: progress)
            lock.unlock()
            task.resume()
        }
    }

    // MARK: Delegate

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        lock.lock()
        let entry = pending[task.taskIdentifier]
        lock.unlock()
        guard let entry else { return }
        let fraction = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        Task { @MainActor in entry.progress(fraction) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        pending[dataTask.taskIdentifier]?.response = response
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        lock.lock()
        pending[dataTask.taskIdentifier]?.received.append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        lock.lock()
        let entry = pending.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let entry else { return }
        if let error {
            entry.continuation.resume(throwing: error)
        } else if let response = entry.response {
            entry.continuation.resume(returning: (entry.received, response))
        } else {
            entry.continuation.resume(throwing: APIError.invalidResponse)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            AppDelegate.finishBackgroundEvents()
        }
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, UIApplicationDelegate {
    private static var backgroundCompletionHandler: (() -> Void)?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions:
                     [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        BackgroundUploadManager.register()
        return true
    }

    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        // Touch the session so its delegate starts receiving events.
        _ = BackgroundUploadManager.shared.session
        Self.backgroundCompletionHandler = completionHandler
    }

    static func finishBackgroundEvents() {
        backgroundCompletionHandler?()
        backgroundCompletionHandler = nil
    }
}
