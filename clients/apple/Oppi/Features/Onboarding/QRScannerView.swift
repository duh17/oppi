import UIKit
import VisionKit

/// Scans an Oppi pairing QR code with VisionKit and reports the first code
/// that decodes: a signed or unsigned v3 invite payload, or an invite URL.
/// Other QR codes are ignored and scanning continues. Presented in a
/// navigation sheet with Cancel.
@MainActor
final class QRScannerViewController: UIViewController, DataScannerViewControllerDelegate {
    /// The scanner needs a camera and on-device recognition (not the simulator).
    static var isAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    private let onScan: (QRScannerViewController, ServerCredentials) -> Void
    private let scanner = DataScannerViewController(
        recognizedDataTypes: [.barcode(symbologies: [.qr])],
        qualityLevel: .balanced,
        recognizesMultipleItems: false,
        isHighFrameRateTrackingEnabled: false,
        isHighlightingEnabled: true
    )
    private var didScan = false

    init(onScan: @escaping (QRScannerViewController, ServerCredentials) -> Void) {
        self.onScan = onScan
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Scan QR Code")
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .cancel,
            primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                Router.finish(self)
            }
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        scanner.delegate = self
        addChild(scanner)
        scanner.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scanner.view)
        NSLayoutConstraint.activate([
            scanner.view.topAnchor.constraint(equalTo: view.topAnchor),
            scanner.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scanner.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scanner.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        scanner.didMove(toParent: self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !didScan, !scanner.isScanning {
            try? scanner.startScanning()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        scanner.stopScanning()
    }

    func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
        handle(item)
    }

    func dataScanner(
        _ dataScanner: DataScannerViewController,
        didAdd addedItems: [RecognizedItem],
        allItems: [RecognizedItem]
    ) {
        // The first QR code found is accepted without a tap.
        if let first = addedItems.first {
            handle(first)
        }
    }

    private func handle(_ item: RecognizedItem) {
        guard !didScan,
              case .barcode(let barcode) = item,
              let payload = barcode.payloadStringValue,
              let credentials = ServerCredentials.decodeInvitePayload(payload)
                ?? ServerCredentials.decodeInviteURLString(payload)
        else { return }
        didScan = true
        scanner.stopScanning()
        onScan(self, credentials)
    }
}
