import SwiftUI

struct SettingsStoragePage: View {
    @State private var cacheSizeText: String?
    @State private var confirmsClearCache = false

    static func formattedCacheSize() async -> String {
        let bytes = await TimelineCache.shared.diskSize()
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    var body: some View {
        List {
            Section {
                if let cacheSizeText {
                    LabeledContent("Local Cache", value: cacheSizeText)
                }
            } footer: {
                Text("Session history and server details Oppi keeps on this device so screens open quickly.")
            }

            Section {
                LabeledContent("Version", value: appVersionLabel)
            }

            Section {
                Button("Clear Local Cache", role: .destructive) {
                    confirmsClearCache = true
                }
            }
        }
        .settingsPage("Storage & About")
        .task { cacheSizeText = await Self.formattedCacheSize() }
        .confirmationDialog(
            "Clear Local Cache?",
            isPresented: $confirmsClearCache,
            titleVisibility: .visible
        ) {
            Button("Clear Local Cache", role: .destructive) {
                Task.detached {
                    await TimelineCache.shared.clear()
                    let formatted = await Self.formattedCacheSize()
                    await MainActor.run { cacheSizeText = formatted }
                }
            }
        } message: {
            Text("Oppi downloads it from your servers again when needed.")
        }
    }

    private var appVersionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        return "\(version) (\(build))"
    }
}
