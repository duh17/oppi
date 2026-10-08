import SwiftUI

/// The one lock indicator for servers, workspaces, and sessions: `lock.fill`
/// while locked, `lock.open.fill` while unlocked for now. Place it right
/// after the item's name, before any value or status.
struct LockBadge: View {
    let state: ScopedLockState

    var body: some View {
        switch state {
        case .none:
            EmptyView()
        case .locked:
            symbol("lock.fill")
                .accessibilityLabel("Locked")
                .accessibilityIdentifier("lockBadge.locked")
        case .unlocked:
            symbol("lock.open.fill")
                .accessibilityLabel("Unlocked")
                .accessibilityIdentifier("lockBadge.unlocked")
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.themeComment)
            .fixedSize()
    }
}

/// Shows `content` only while `target` is reachable; otherwise a lock cover
/// with Unlock. Content is torn down while locked, so nothing from a locked
/// scope (streams, toolbars, titles) stays mounted behind it. This is what
/// enforces a lock when an unlock expires under an open screen or a route
/// reaches a destination without passing a navigation gate.
struct ScopedLockGate<Content: View, Accessory: View>: View {
    let target: ScopedLockTarget?
    let title: String
    @ViewBuilder let accessory: () -> Accessory
    @ViewBuilder let content: () -> Content

    @State private var locks = ScopedLockService.shared

    init(
        target: ScopedLockTarget?,
        title: String,
        @ViewBuilder accessory: @escaping () -> Accessory,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.target = target
        self.title = title
        self.accessory = accessory
        self.content = content
    }

    var body: some View {
        if let target, locks.isLocked(target) {
            ScopedLockCoverView(title: title, isAuthenticating: locks.isAuthenticating) {
                Task { _ = await locks.authorize(target) }
            } accessory: {
                accessory()
            }
        } else {
            content()
        }
    }
}

extension ScopedLockGate where Accessory == EmptyView {
    init(
        target: ScopedLockTarget?,
        title: String,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(target: target, title: title, accessory: { EmptyView() }, content: content)
    }
}

/// Opaque stand-in for a locked server, workspace, or session.
struct ScopedLockCoverView<Accessory: View>: View {
    let title: String
    let isAuthenticating: Bool
    /// Overrides the Unlock button (a cover that cannot unlock closes instead).
    var actionTitle: String? = nil
    var actionSystemImage: String? = nil
    let onUnlock: () -> Void
    @ViewBuilder let accessory: () -> Accessory

    @State private var appLock = AppLockService.shared

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.themeBg)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.themeComment)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.themeFg)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text("Locked")
                    .font(.subheadline)
                    .foregroundStyle(.themeComment)

                Button(action: onUnlock) {
                    Label(actionTitle ?? unlockTitle, systemImage: actionSystemImage ?? appLock.method.systemImage)
                        .frame(minWidth: 180)
                }
                .buttonStyle(.borderedProminent)
                .tint(.themeBlue)
                .controlSize(.large)
                .disabled(isAuthenticating)
                .padding(.top, 6)
                .accessibilityIdentifier("scopedLock.unlock")

                accessory()
            }
            .padding(32)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("scopedLock.cover")
    }

    private var unlockTitle: String {
        appLock.method == .passcode
            ? String(localized: "Unlock")
            : String(localized: "Unlock with \(appLock.method.name)")
    }
}
