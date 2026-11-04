//
//  SetupCodeViews.swift
//  Navidrome Uploader
//
//  One-scan setup: a QR code carrying {"server","token"} moves the
//  setup from a configured device to a fresh one. The code contains
//  the upload token — it is a password in picture form.
//

import AVFoundation
import CoreImage
import SwiftUI
import UIKit

struct SetupPayload: Codable {
    var server: String
    var token: String

    var jsonString: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func parse(_ raw: String) -> SetupPayload? {
        guard let data = raw.data(using: .utf8),
              let payload = try? JSONDecoder().decode(SetupPayload.self, from: data),
              payload.server.hasPrefix("http"), !payload.token.isEmpty
        else { return nil }
        return payload
    }
}

enum QRCodeGenerator {
    static func image(from string: String) -> UIImage? {
        // Classic name-based CoreImage API: the typed CIFilter
        // convenience constructors are not exposed to this target.
        guard let filter = CIFilter(name: "CIQRCodeGenerator")
        else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(
            by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent)
        else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - Show my code

struct ShowSetupCodeView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer()
                if settings.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView(
                        "No token saved yet",
                        systemImage: "qrcode",
                        description: Text("Save your upload token in Settings first \u{2014} the setup code carries it to the other device.")
                    )
                } else if let payload = SetupPayload(
                    server: settings.baseURLString,
                    token: settings.token.trimmingCharacters(in: .whitespacesAndNewlines)
                ).jsonString, let image = QRCodeGenerator.image(from: payload) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 240, height: 240)
                        .padding(16)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 20))
                    Text("Point the other device\u{2019}s NaviUpload at this code (Settings \u{2192} Scan a setup QR code).")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                    Text("It contains your upload token \u{2014} don\u{2019}t share it with anyone else.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                Spacer()
            }
            .navigationTitle("My setup code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Scan a code

struct ScanSetupCodeView: View {
    @Environment(\.dismiss) private var dismiss
    var onPayload: (SetupPayload) -> Void

    @State private var failed = false

    var body: some View {
        NavigationStack {
            ZStack {
                QRScannerView { raw in
                    if let payload = SetupPayload.parse(raw) {
                        onPayload(payload)
                    } else {
                        failed = true
                    }
                }
                .ignoresSafeArea()
                VStack {
                    Spacer()
                    Text(failed
                         ? "That code was not a NaviUpload setup code. Keep pointing at the code\u{2026}"
                         : "Point at a NaviUpload setup code")
                        .font(.footnote.bold())
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.bottom, 28)
                }
            }
            .navigationTitle("Scan setup code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

/// Minimal camera QR scanner (AVFoundation). Calls back once per code.
private struct QRScannerView: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode)
    }

    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: ScannerViewController,
                                context: Context) {}

    final class Coordinator: NSObject, ScannerDelegate {
        private let onCode: (String) -> Void
        private var fired = false

        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
        }

        func scannerDidFind(_ code: String) {
            guard !fired else { return }
            fired = true
            onCode(code)
        }
    }
}

private protocol ScannerDelegate: AnyObject {
    func scannerDidFind(_ code: String)
}

private final class ScannerViewController: UIViewController,
                                           AVCaptureMetadataOutputObjectsDelegate {
    weak var delegate: ScannerDelegate?
    private var session: AVCaptureSession?
    private var preview: AVCaptureVideoPreviewLayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device)
        else { return }
        let session = AVCaptureSession()
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.frame = view.layer.bounds
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        self.session = session
        self.preview = preview
        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.layer.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        session?.stopRunning()
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        for object in metadataObjects {
            if let readable = object as? AVMetadataMachineReadableCodeObject,
               let value = readable.stringValue {
                delegate?.scannerDidFind(value)
                return
            }
        }
    }
}
