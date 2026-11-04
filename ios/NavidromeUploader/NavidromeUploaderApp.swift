//
//  NavidromeUploaderApp.swift
//  Navidrome Uploader
//
//  App entry point. Creates the shared observable stores (settings +
//  upload history) and injects them into the environment.
//

import SwiftUI
import UIKit

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
                .onAppear { KeyboardTapHandler.shared.install() }
        }
    }
}

/// Tap anywhere outside a text field / editor and the keyboard
/// closes. The recognizer never cancels touches, recognizes
/// alongside every other gesture, and ignores taps that land inside
/// a text input (so fields and the link editor behave normally).
private final class KeyboardTapHandler: NSObject,
                                        UIGestureRecognizerDelegate {
    static let shared = KeyboardTapHandler()
    private var installed = false

    func install() {
        guard !installed else { return }
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap(\.windows)
        guard let window = windows.first(where: \.isKeyWindow)
            ?? windows.first else { return }
        installed = true
        let tap = UITapGestureRecognizer(
            target: self, action: #selector(dismiss))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        window.addGestureRecognizer(tap)
    }

    @objc private func dismiss() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil)
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        var view = touch.view
        while let current = view {
            if current is UITextField || current is UITextView {
                return false
            }
            view = current.superview
        }
        return true
    }

    func gestureRecognizer(
        _ recognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { true }
}
