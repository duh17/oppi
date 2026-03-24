import SwiftUI
import OSLog

private let logger = Logger(subsystem: "dev.chenda.OppiMac", category: "DoctorView")

/// Runs `oppi doctor` via the server CLI and displays structured results.
struct DoctorView: View {

    @State private var checks: [DoctorCheck] = []
    @State private var rawOutput: String?
    @State private var isRunning = false
    @State private var error: String?

    var body: some View {
        Form {
            if isRunning {
                Section {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("Running diagnostics...")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !checks.isEmpty {
                Section("Checks") {
                    ForEach(checks) { check in
                        HStack {
                            Image(systemName: check.icon)
                                .foregroundStyle(check.color)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(check.name)
                                    .fontWeight(.medium)
                                if let detail = check.detail {
                                    Text(detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(check.statusLabel)
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(check.color.opacity(0.15))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }
                }
            }

            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }

            if let rawOutput, !rawOutput.isEmpty {
                Section("Raw Output") {
                    Text(rawOutput)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }

            Section {
                Button("Re-run Diagnostics") {
                    runDoctor()
                }
                .disabled(isRunning)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Doctor")
        .task {
            runDoctor()
        }
    }

    private func runDoctor() {
        isRunning = true
        error = nil
        checks = []
        rawOutput = nil

        Task.detached {
            guard let nodePath = await MainActor.run(body: { ServerProcessManager.resolveNodePath() }) else {
                await MainActor.run {
                    error = "Node.js not found"
                    isRunning = false
                }
                return
            }
            guard let cliPath = await MainActor.run(body: { ServerProcessManager.resolveServerCLIPath() }) else {
                await MainActor.run {
                    error = "Server CLI not found"
                    isRunning = false
                }
                return
            }

            do {
                let result = try await ProcessRunner.run(
                    executable: nodePath,
                    arguments: [cliPath, "doctor"]
                )

                let parsed = DoctorView.parseOutput(result.stdout, exitCode: result.exitCode)

                await MainActor.run {
                    checks = parsed
                    rawOutput = result.stdout
                    isRunning = false
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    isRunning = false
                }
            }
        }
    }

    /// Parse doctor output lines. Looks for common patterns:
    /// - Lines starting with check mark, x, or warning symbols
    /// - Lines with "OK", "WARN", "FAIL", "PASS" prefixes
    private nonisolated static func parseOutput(_ output: String, exitCode: Int32) -> [DoctorCheck] {
        let lines = output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var results: [DoctorCheck] = []

        for line in lines {
            if let check = parseLine(line) {
                results.append(check)
            }
        }

        // If no structured output was parsed, create a single check from exit code
        if results.isEmpty {
            results.append(DoctorCheck(
                name: "Doctor",
                status: exitCode == 0 ? .pass : .fail,
                detail: output.isEmpty ? nil : String(output.prefix(200))
            ))
        }

        return results
    }

    private nonisolated static func parseLine(_ line: String) -> DoctorCheck? {
        // Match: ✓ or ✔ or [PASS] or [OK]
        if line.hasPrefix("✓") || line.hasPrefix("✔") || line.hasPrefix("[PASS]") || line.hasPrefix("[OK]") {
            let name = line
                .replacingOccurrences(of: "^[✓✔]\\s*", with: "", options: .regularExpression)
                .replacingOccurrences(of: "^\\[(PASS|OK)\\]\\s*", with: "", options: .regularExpression)
            return DoctorCheck(name: name, status: .pass, detail: nil)
        }

        // Match: ✗ or ✘ or [FAIL] or [ERROR]
        if line.hasPrefix("✗") || line.hasPrefix("✘") || line.hasPrefix("[FAIL]") || line.hasPrefix("[ERROR]") {
            let name = line
                .replacingOccurrences(of: "^[✗✘]\\s*", with: "", options: .regularExpression)
                .replacingOccurrences(of: "^\\[(FAIL|ERROR)\\]\\s*", with: "", options: .regularExpression)
            return DoctorCheck(name: name, status: .fail, detail: nil)
        }

        // Match: ⚠ or [WARN]
        if line.hasPrefix("⚠") || line.hasPrefix("[WARN]") {
            let name = line
                .replacingOccurrences(of: "^⚠\\s*", with: "", options: .regularExpression)
                .replacingOccurrences(of: "^\\[WARN\\]\\s*", with: "", options: .regularExpression)
            return DoctorCheck(name: name, status: .warn, detail: nil)
        }

        return nil
    }
}

// MARK: - Types

private struct DoctorCheck: Identifiable {
    let id = UUID()
    let name: String
    let status: Status
    let detail: String?

    enum Status {
        case pass, warn, fail
    }

    var icon: String {
        switch status {
        case .pass: "checkmark.circle.fill"
        case .warn: "exclamationmark.triangle.fill"
        case .fail: "xmark.circle.fill"
        }
    }

    var color: Color {
        switch status {
        case .pass: .green
        case .warn: .orange
        case .fail: .red
        }
    }

    var statusLabel: String {
        switch status {
        case .pass: "Pass"
        case .warn: "Warning"
        case .fail: "Fail"
        }
    }
}
