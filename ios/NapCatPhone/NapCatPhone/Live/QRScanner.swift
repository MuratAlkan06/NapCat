import AVFoundation
import SwiftUI
import VisionKit

/// Where the camera stands for the pairing scan (F4 slice S-PAIR-B).
enum CameraState: Equatable, Sendable, CaseIterable {
    /// Allowed, and this iPhone can scan: the viewfinder is live.
    case ready
    /// Not asked yet: the screen asks first, in its own words.
    case notAsked
    /// Refused in Settings, or restricted on this iPhone.
    case off
    /// This device has no scanner (the simulator).
    case unsupported
}

/// THE seam over the camera's permission and the scanner's support. The
/// live one is `LiveCameraAccess`; fixtures and tests say what they are
/// told and draw no camera.
@MainActor
protocol CameraAccess {
    /// Whether the viewfinder is the real camera.
    var isLive: Bool { get }
    func state() -> CameraState
    /// Asks for the camera (the system's prompt, once), then reads again.
    func request() async -> CameraState
}

/// The live `CameraAccess`: VisionKit's scanner support, the camera's
/// authorization, and the system's one camera prompt. The app's usage
/// description says why it asks.
struct LiveCameraAccess: CameraAccess {
    var isLive: Bool { true }

    func state() -> CameraState {
        guard DataScannerViewController.isSupported else { return .unsupported }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return DataScannerViewController.isAvailable ? .ready : .off
        case .notDetermined: return .notAsked
        case .denied, .restricted: return .off
        @unknown default: return .off
        }
    }

    func request() async -> CameraState {
        _ = await AVCaptureDevice.requestAccess(for: .video)
        return state()
    }
}

/// A pairing code as the camera read it (F4 slice S-PAIR-C1.6, #172): the
/// only thing a ceremony scans (`PairingCeremony.scanned`). Outside the
/// fixtures it is built in ONE place, the live scanner's hand-on of the
/// first QR code it reads (lint-locked), so a code reaches a live ceremony
/// through the camera alone: the app takes none from a URL, a deep link,
/// the pasteboard or a launch argument. What it holds is read strictly by
/// the ceremony and never shown, logged or kept: it describes, prints and
/// reflects as its type's name alone.
struct ScannedCode: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let payload: String

    var description: String { "ScannedCode(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

/// The live viewfinder: VisionKit's data scanner, QR codes only, one item
/// at a time, with Apple's own guidance and highlighting. It hands on the
/// FIRST code it reads and stops: one scan per ceremony, checked again by
/// the ceremony itself. What a code says is never shown; the ceremony reads
/// it strictly or refuses it.
struct QRScannerView: UIViewControllerRepresentable {
    let scanned: @MainActor (ScannedCode) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
                                                recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false,
                                                isPinchToZoomEnabled: false, isGuidanceEnabled: true, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        guard !context.coordinator.handedOn, !scanner.isScanning else { return }
        try? scanner.startScanning()
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(scanned: scanned)
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let scanned: @MainActor (ScannedCode) -> Void
        /// Set once the first code is handed on; nothing after it is.
        private(set) var handedOn = false

        init(scanned: @escaping @MainActor (ScannedCode) -> Void) {
            self.scanned = scanned
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            guard !handedOn else { return }
            for item in addedItems {
                guard case .barcode(let code) = item, let payload = code.payloadStringValue else { continue }
                handedOn = true
                dataScanner.stopScanning()
                scanned(ScannedCode(payload: payload))
                return
            }
        }
    }
}
