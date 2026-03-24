import SwiftUI
import OSLog

private let logger = Logger(subsystem: "dev.chenda.OppiMac", category: "PrerequisitesView")

/// Step 1: Check that Node.js, pi CLI, and port 7749 are available.
struct PrerequisitesView: View {

    let onContinue: () -> Void

    @State private var nodeStatus = PrereqStatus.checking
    @State private var piStatus = PrereqStatus.checking
    @State private var portStatus = PrereqStatus.checking

    private var allPassed: Bool {
        nodeStatus.passed && piStatus.passed && portStatus.passed
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                Text("Welcome to Oppi")
                    .font(.title)
                    .fontWeight(.semibold)

                Text("Checking your system...")
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 24)

            Spacer()

            VStack(alignment: .leading, spacing: 12) {
                PrereqRow(label: "Node.js", status: nodeStatus)
                PrereqRow(label: "pi CLI", status: piStatus)
                PrereqRow(label: "Port 7749", status: portStatus)
            }
            .frame(maxWidth: 320)

            Spacer()

            HStack {
                Spacer()
                if allPassed {
                    Button("Continue") {
                        onContinue()
                    }
                    .keyboardShortcut(.defaultAction)
                } else if !isChecking {
                    Button("Re-check") {
                        runChecks()
                    }
                }
            }
            .padding(20)
        }
        .task {
            runChecks()
        }
    }

    private var isChecking: Bool {
        nodeStatus == .checking || piStatus == .checking || portStatus == .checking
    }

    private func runChecks() {
        nodeStatus = .checking
        piStatus = .checking
        portStatus = .checking

        Task.detached {
            let node = await PrerequisitesView.checkNode()
            let pi = await PrerequisitesView.checkPi()
            let port = PrerequisitesView.checkPort(7749)

            await MainActor.run {
                nodeStatus = node
                piStatus = pi
                portStatus = port
            }
        }
    }

    // MARK: - Checks

    private static func checkNode() async -> PrereqStatus {
        guard let path = await ProcessRunner.which("node") else {
            return .failed("Not found — install from nodejs.org")
        }
        guard let version = await ProcessRunner.version(path) else {
            return .failed("Found at \(path) but could not get version")
        }
        return .passed(version)
    }

    private static func checkPi() async -> PrereqStatus {
        guard let path = await ProcessRunner.which("pi") else {
            return .failed("Not found — npm install -g @anthropic-ai/claude-code")
        }
        guard let version = await ProcessRunner.version(path) else {
            return .failed("Found at \(path) but could not get version")
        }
        return .passed(version)
    }

    private nonisolated static func checkPort(_ port: UInt16) -> PrereqStatus {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return .failed("Could not create socket")
        }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian

        // Allow address reuse so we don't block the port
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if bindResult == 0 {
            return .passed("Available")
        } else {
            return .failed("Port is in use")
        }
    }
}

// MARK: - Status type

private enum PrereqStatus: Equatable {
    case checking
    case passed(String)
    case failed(String)

    var passed: Bool {
        if case .passed = self { return true }
        return false
    }
}

// MARK: - Row view

private struct PrereqRow: View {

    let label: String
    let status: PrereqStatus

    var body: some View {
        HStack {
            switch status {
            case .checking:
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 16, height: 16)
            case .passed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }

            Text(label)
                .fontWeight(.medium)

            Spacer()

            switch status {
            case .checking:
                Text("Checking...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .passed(let detail):
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .failed(let reason):
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}
