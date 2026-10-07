import SwiftUI
import UIKit

/// Opaque App Lock cover. While locked it offers Unlock; while only
/// obscuring an inactive or backgrounded scene it shows the app identity.
struct AppLockCoverView: View {
    let service: AppLockService

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.themeBg)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                AppLockAppIcon()
                Text("Oppi")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.themeFg)

                if service.isLocked {
                    lockedContent
                }
            }
            .padding(32)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("appLock.cover")
    }

    @ViewBuilder
    private var lockedContent: some View {
        Text(service.unlockFailed ? "Couldn’t verify it’s you. Try again." : "Oppi is locked.")
            .font(.subheadline)
            .foregroundStyle(.themeComment)
            .multilineTextAlignment(.center)
            .accessibilityIdentifier("appLock.status")

        Button {
            Task { await service.unlock() }
        } label: {
            Label(unlockTitle, systemImage: service.method.systemImage)
                .frame(minWidth: 180)
        }
        .buttonStyle(.borderedProminent)
        .tint(.themeBlue)
        .controlSize(.large)
        .disabled(service.isAuthenticating)
        .padding(.top, 8)
        .accessibilityIdentifier("appLock.unlock")
    }

    private var unlockTitle: String {
        service.method == .passcode
            ? String(localized: "Unlock")
            : String(localized: "Unlock with \(service.method.name)")
    }
}

/// Hides the app's SwiftUI content from VoiceOver while Oppi is locked; the
/// cover sits in its own window above it.
struct AppLockAccessibilityHidden: ViewModifier {
    @State private var appLock = AppLockService.shared

    func body(content: Content) -> some View {
        content.accessibilityHidden(appLock.isLocked)
    }
}

/// The installed app icon, or a lock symbol when the bundle has none.
private struct AppLockAppIcon: View {
    private static let image: UIImage? = {
        let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any]
        let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        let files = primary?["CFBundleIconFiles"] as? [String]
        let names = (files ?? []).reversed() + [primary?["CFBundleIconName"] as? String, "AppIcon"].compactMap { $0 }
        return names.lazy.compactMap { UIImage(named: $0) }.first
    }()

    var body: some View {
        Group {
            if let image = Self.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else {
                Image(systemName: "lock.fill")
                    .resizable()
                    .scaledToFit()
                    .padding(14)
                    .foregroundStyle(.themeBlue)
            }
        }
        .frame(width: 80, height: 80)
        .accessibilityHidden(true)
    }
}
