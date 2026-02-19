import SwiftUI
import VisionKit

/// QR code scanner using DataScannerViewController (VisionKit, iOS 16+).
///
/// Supports unsigned v3 invite JSON and deep-link invite URLs.
struct QRScannerView: UIViewControllerRepresentable {
    let onScan: (ServerCredentials) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {
        if !vc.isScanning {
            try? vc.startScanning()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan)
    }

    class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScan: (ServerCredentials) -> Void
        private var didScan = false

        init(onScan: @escaping (ServerCredentials) -> Void) {
            self.onScan = onScan
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didTapOn item: RecognizedItem
        ) {
            handleItem(item, scanner: dataScanner)
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd items: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            // Auto-accept first QR code found
            if let first = items.first {
                handleItem(first, scanner: dataScanner)
            }
        }

        private func handleItem(_ item: RecognizedItem, scanner: DataScannerViewController) {
            guard !didScan else { return }

            guard case .barcode(let barcode) = item,
                  let payload = barcode.payloadStringValue
            else { return }

            guard let credentials = ServerCredentials.decodeInvitePayload(payload)
                ?? ServerCredentials.decodeInviteURLString(payload)
            else { return }

            didScan = true
            scanner.stopScanning()

            Task { @MainActor in
                onScan(credentials)
            }
        }
    }
}
