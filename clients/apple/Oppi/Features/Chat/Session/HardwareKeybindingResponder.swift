import GameController
import UIKit

/// Timeline-only first responder for hardware-keyboard catalog chords.
///
/// Lives on the collection view, not on a view controller that also hosts the
/// composer, so vim letters cannot steal typing. Cmd-Return send stays on
/// `PastableTextView`.
final class HardwareKeybindingResponder: UIView {
    var mode: KeybindingMode = KeybindingPreferenceStore().mode
    var focus: KeybindingFocus = .timeline
    var composerIsFirstResponder = false
    /// This view never hosts the composer. Keep the flag explicit for tests.
    let hostsComposer = false
    var selectedToolRowID: String?
    var onAction: ((KeybindingAction) -> Void)?

    /// Test seam. Production reads `GCKeyboard.coalesced`.
    var hardwareKeyboardConnectedOverride: Bool?

    var hardwareKeyboardConnected: Bool {
        hardwareKeyboardConnectedOverride ?? (GCKeyboard.coalesced != nil)
    }

    private var keyboardObservers: [NSObjectProtocol] = []
    private static let suppressedInputView = UIView(frame: .zero)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = .clear
        observeHardwareKeyboard()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func makeRequest() -> HardwareKeybindingAdapter.Request {
        HardwareKeybindingAdapter.Request(
            hardwareKeyboardConnected: hardwareKeyboardConnected,
            userInterfaceIdiom: traitCollection.userInterfaceIdiom,
            mode: mode,
            focus: focus,
            hostsComposer: hostsComposer,
            composerIsFirstResponder: composerIsFirstResponder
        )
    }

    override var canBecomeFirstResponder: Bool {
        HardwareKeybindingAdapter.shouldBecomeFirstResponder(makeRequest())
    }

    /// Never present the software keyboard if this view becomes first responder.
    override var inputView: UIView? {
        Self.suppressedInputView
    }

    override var keyCommands: [UIKeyCommand]? {
        let commands = HardwareKeybindingAdapter.registeredChords(for: makeRequest())
            .compactMap { chord in
                HardwareKeybindingAdapter.uiKeyCommand(
                    for: chord,
                    action: #selector(handleKeyCommand(_:))
                )
            }
        return commands.isEmpty ? nil : commands
    }

    @objc func handleKeyCommand(_ command: UIKeyCommand) {
        guard let chord = HardwareKeybindingAdapter.chord(from: command) else { return }
        let action = HardwareKeybindingAdapter.action(for: chord, request: makeRequest())
        guard HardwareKeybindingAdapter.consumes(action), let action else { return }
        onAction?(action)
    }

    @discardableResult
    func claimFocusIfPossible() -> Bool {
        composerIsFirstResponder = false
        if focus == .composer {
            focus = .timeline
        }
        guard canBecomeFirstResponder else { return false }
        return becomeFirstResponder()
    }

    private func observeHardwareKeyboard() {
        let center = NotificationCenter.default
        keyboardObservers.append(
            center.addObserver(
                forName: .GCKeyboardDidConnect,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.reloadInputViews()
                }
            }
        )
        keyboardObservers.append(
            center.addObserver(
                forName: .GCKeyboardDidDisconnect,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if self.isFirstResponder, !self.canBecomeFirstResponder {
                        self.resignFirstResponder()
                    }
                    self.reloadInputViews()
                }
            }
        )
    }
}
