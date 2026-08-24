import Combine
import Foundation
import SwiftUI
import TipKit
import UIKit

struct FeatureEducationTipDescriptor: Hashable, Sendable {
    let id: String
    let title: String
    let message: String
    let systemImageName: String
}

final class FeatureEducationTipPresentationStore: @unchecked Sendable {
    static let standard = FeatureEducationTipPresentationStore()

    private let defaults: UserDefaults
    private let shownTipIDsKey: String

    init(
        defaults: UserDefaults = .standard,
        namespace: String = "featureEducationTips"
    ) {
        self.defaults = defaults
        self.shownTipIDsKey = "oppi.\(namespace).shownTipIDs.v1"
    }

    func hasShownTip(id: String) -> Bool {
        shownTipIDs.contains(id)
    }

    func markShown(id: String) {
        var ids = shownTipIDs
        guard ids.insert(id).inserted else { return }
        defaults.set(Array(ids).sorted(), forKey: shownTipIDsKey)
    }

    func reset() {
        defaults.removeObject(forKey: shownTipIDsKey)
    }

    private var shownTipIDs: Set<String> {
        Set(defaults.stringArray(forKey: shownTipIDsKey) ?? [])
    }
}

@MainActor
final class FeatureEducationTipPresentationCoordinator: ObservableObject {
    struct ActivePresentation: Equatable {
        let tipID: String
        let ownerID: UUID
    }

    static let shared = FeatureEducationTipPresentationCoordinator(
        store: .standard
    )

    @Published private(set) var revision = 0
    private(set) var activePresentation: ActivePresentation?

    private let store: FeatureEducationTipPresentationStore

    init(store: FeatureEducationTipPresentationStore) {
        self.store = store
    }

    func claim(tipID: String, ownerID: UUID, force: Bool = false) -> Bool {
        if let activePresentation {
            return activePresentation.tipID == tipID && activePresentation.ownerID == ownerID
        }
        guard force || !store.hasShownTip(id: tipID) else { return false }
        activePresentation = ActivePresentation(tipID: tipID, ownerID: ownerID)
        if !force {
            store.markShown(id: tipID)
        }
        bumpRevision()
        return true
    }

    func release(tipID: String, ownerID: UUID) {
        guard activePresentation == ActivePresentation(tipID: tipID, ownerID: ownerID) else { return }
        activePresentation = nil
        bumpRevision()
    }

    func markCompleted(tipID: String) {
        store.markShown(id: tipID)
        guard activePresentation?.tipID == tipID else {
            bumpRevision()
            return
        }
        activePresentation = nil
        bumpRevision()
    }

    func isActive(tipID: String, ownerID: UUID) -> Bool {
        activePresentation == ActivePresentation(tipID: tipID, ownerID: ownerID)
    }

#if DEBUG
    func resetForTesting() {
        activePresentation = nil
        store.reset()
        bumpRevision()
    }
#endif

    private func bumpRevision() {
        revision &+= 1
    }
}

@MainActor
final class FeatureEducationTipBannerView: UIView {
    static let preferredHeight: CGFloat = 60
    private static let minimumControlSize: CGFloat = 44

    private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
    private let iconContainer = UIView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private var onClose: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleThemeDidChange),
            name: .oppiThemeDidChange,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc
    private func handleThemeDidChange() {
        applyThemeColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.preferredHeight)
    }

    func configure(descriptor: FeatureEducationTipDescriptor, onClose: (() -> Void)?) {
        applyThemeColors()
        iconView.image = UIImage(systemName: descriptor.systemImageName)
        titleLabel.text = descriptor.title
        messageLabel.text = descriptor.message
        accessibilityIdentifier = "feature-tip.\(descriptor.id).tip"
        accessibilityLabel = "\(descriptor.title). \(descriptor.message)"
        self.onClose = onClose
    }

    private func applyThemeColors() {
        let palette = ThemeRuntimeState.currentPalette()
        let accent = UIColor(palette.cyan)

        // The banner fill sits on a UIVisualEffectView blur, satisfying the
        // floating-control role's blur pairing.
        blurView.contentView.backgroundColor = UIColor(
            ThemeSurfaceStyle.resolve(.floatingControl, palette: palette).fill
        )
        layer.borderColor = UIColor(palette.comment).withAlphaComponent(0.22).cgColor
        titleLabel.textColor = UIColor(palette.fg)
        messageLabel.textColor = UIColor(palette.fgDim)
        closeButton.tintColor = UIColor(palette.fgDim)
        iconContainer.backgroundColor = UIColor(palette.cyan).withAlphaComponent(0.16)
        iconView.tintColor = accent
    }

    private func setupViews() {
        isAccessibilityElement = false
        accessibilityTraits = [.staticText]

        layer.cornerRadius = 18
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        layer.borderWidth = 1

        blurView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blurView)

        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.layer.cornerRadius = 14
        iconContainer.layer.cornerCurve = .continuous

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentMode = .scaleAspectFit
        iconContainer.addSubview(iconView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
            for: .systemFont(ofSize: 15, weight: .semibold)
        )
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 1
        titleLabel.accessibilityIdentifier = "feature-tip.title"

        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.font = .preferredFont(forTextStyle: .caption1)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.numberOfLines = 2
        messageLabel.accessibilityIdentifier = "feature-tip.message"

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.accessibilityLabel = "Dismiss tip"
        closeButton.accessibilityIdentifier = "feature-tip.dismiss"
        closeButton.addTarget(self, action: #selector(handleClose), for: .touchUpInside)

        let textStack = UIStackView(arrangedSubviews: [titleLabel, messageLabel])
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.axis = .vertical
        textStack.spacing = 2

        let contentStack = UIStackView(arrangedSubviews: [iconContainer, textStack, closeButton])
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .horizontal
        contentStack.alignment = .center
        contentStack.spacing = 10
        addSubview(contentStack)

        applyThemeColors()

        NSLayoutConstraint.activate([
            blurView.leadingAnchor.constraint(equalTo: leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: trailingAnchor),
            blurView.topAnchor.constraint(equalTo: topAnchor),
            blurView.bottomAnchor.constraint(equalTo: bottomAnchor),

            iconContainer.widthAnchor.constraint(equalToConstant: 32),
            iconContainer.heightAnchor.constraint(equalToConstant: 32),
            iconView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 17),
            iconView.heightAnchor.constraint(equalToConstant: 17),

            closeButton.widthAnchor.constraint(equalToConstant: Self.minimumControlSize),
            closeButton.heightAnchor.constraint(equalToConstant: Self.minimumControlSize),

            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    @objc private func handleClose() {
        onClose?()
    }
}

struct FeatureEducationTipBannerRepresentable: UIViewRepresentable {
    let descriptor: FeatureEducationTipDescriptor
    let onClose: () -> Void

    func makeUIView(context: Context) -> FeatureEducationTipBannerView {
        let view = FeatureEducationTipBannerView()
        view.configure(descriptor: descriptor, onClose: onClose)
        return view
    }

    func updateUIView(_ uiView: FeatureEducationTipBannerView, context: Context) {
        uiView.configure(descriptor: descriptor, onClose: onClose)
    }
}

struct FeatureEducationTipBannerHost<TipType: Tip>: View {
    let tip: TipType
    let descriptor: FeatureEducationTipDescriptor
    let contentInsets: EdgeInsets

    @ObservedObject private var coordinator = FeatureEducationTipPresentationCoordinator.shared
    @State private var ownerID = UUID()
    @State private var shouldDisplay = false
    @State private var isPresented = false

    init(
        tip: TipType,
        descriptor: FeatureEducationTipDescriptor,
        contentInsets: EdgeInsets = EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
    ) {
        self.tip = tip
        self.descriptor = descriptor
        self.contentInsets = contentInsets
    }

    var body: some View {
        ZStack(alignment: .top) {
            if isPresented {
                FeatureEducationTipBannerRepresentable(descriptor: descriptor) {
                    tip.invalidate(reason: .tipClosed)
                    coordinator.release(tipID: descriptor.id, ownerID: ownerID)
                    isPresented = false
                }
                .frame(height: FeatureEducationTipBannerView.preferredHeight)
                .padding(contentInsets)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(height: reservedHeight)
        .clipped()
        .task {
            shouldDisplay = tip.shouldDisplay
            refreshPresentation()
            for await display in tip.shouldDisplayUpdates {
                shouldDisplay = display
                refreshPresentation()
            }
        }
        .onChange(of: coordinator.revision) { _, _ in
            refreshPresentation()
        }
        .onDisappear {
            guard isPresented else { return }
            coordinator.release(tipID: descriptor.id, ownerID: ownerID)
            isPresented = false
        }
    }

    private var reservedHeight: CGFloat {
        guard isPresented else { return 0 }
        return FeatureEducationTipBannerView.preferredHeight
            + contentInsets.top
            + contentInsets.bottom
    }

    private func refreshPresentation() {
        let eligible = shouldDisplay || forceTipsForTesting
        if isPresented {
            guard eligible, coordinator.isActive(tipID: descriptor.id, ownerID: ownerID) else {
                isPresented = false
                return
            }
            return
        }
        guard eligible else { return }
        isPresented = coordinator.claim(
            tipID: descriptor.id,
            ownerID: ownerID,
            force: forceTipsForTesting
        )
    }

    private var forceTipsForTesting: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("--show-feature-tips-for-testing")
#else
        false
#endif
    }
}
