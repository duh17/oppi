import SwiftUI

struct ShareSessionRedactionSheet: View {
    @Binding var policy: ShareSessionRedactionPolicy

    let preflight: ShareSessionPrepareResult?
    let isAnalyzing: Bool
    let errorMessage: String?
    let isSharing: Bool
    let onRefresh: () -> Void
    let onShare: () -> Void
    let onCancel: () -> Void

    private var findings: [ShareSessionRedactionFinding] {
        preflight?.redaction?.findings ?? []
    }

    private var totalReplacements: Int {
        preflight?.redaction?.totalReplacements ?? 0
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent {
                        Text("Always On")
                            .foregroundStyle(.themeGreen)
                    } label: {
                        Label("Secrets", systemImage: "lock.fill")
                    }

                    Toggle("Email Addresses", isOn: binding(\.emails))
                    Toggle("Phone Numbers", isOn: binding(\.phones))
                    Toggle("User Paths", isOn: binding(\.userPaths))
                    Toggle("IP Addresses", isOn: binding(\.ipAddresses))
                    Toggle("JWT Tokens", isOn: binding(\.jwtAndBearer))
                    Toggle("Names (Heuristic)", isOn: binding(\.namesHeuristic))
                    Toggle("Skills", isOn: binding(\.skills))
                } header: {
                    Text("Redaction Settings")
                } footer: {
                    Text("These settings are remembered for future shares.")
                }

                Section("Redaction Preview") {
                    if isAnalyzing {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Scanning session export…")
                        }
                        .foregroundStyle(.themeComment)
                    }

                    if let errorMessage, !errorMessage.isEmpty {
                        Text(errorMessage)
                            .foregroundStyle(.themeRed)
                            .font(.footnote)
                    }

                    if preflight != nil {
                        Text("Detected \(totalReplacements) replacements")
                            .font(.subheadline.weight(.semibold))
                            .accessibilityIdentifier("share-redaction-summary")

                        if findings.isEmpty {
                            Text("No configured PII findings detected in this preview.")
                                .font(.footnote)
                                .foregroundStyle(.themeComment)
                        } else {
                            ForEach(Array(findings.prefix(6).enumerated()), id: \.offset) { _, finding in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(finding.kind) ×\(finding.count)")
                                        .font(.subheadline.monospaced())
                                    if let sample = finding.samples.first, !sample.isEmpty {
                                        Text(sample)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.themeComment)
                                    }
                                }
                            }

                            if findings.count > 6 {
                                Text("+\(findings.count - 6) more categories")
                                    .font(.footnote)
                                    .foregroundStyle(.themeComment)
                            }
                        }

                        if preflight?.blocked == true {
                            Text("Sharing is currently blocked because residual secrets were detected.")
                                .font(.footnote)
                                .foregroundStyle(.themeOrange)
                        }
                    }

                    Button("Refresh Preview") {
                        onRefresh()
                    }
                    .disabled(isAnalyzing || isSharing)
                }
            }
            .settingsPage("Share Session")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) {
                        onCancel()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    if isSharing {
                        ProgressView()
                            .accessibilityLabel("Sharing")
                    } else {
                        Button("Share", systemImage: "square.and.arrow.up") {
                            onShare()
                        }
                        .disabled(isAnalyzing)
                    }
                }
            }
        }
    }

    private func binding(_ keyPath: WritableKeyPath<ShareSessionRedactionPolicy, Bool>) -> Binding<Bool> {
        Binding(
            get: { policy[keyPath: keyPath] },
            set: { policy[keyPath: keyPath] = $0 }
        )
    }
}
