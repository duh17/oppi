import SwiftUI

/// Step 1: Check that Node.js, the npm-installed CLIs, and port 7749 are available.
struct PrerequisitesView: View {

    let onContinue: () -> Void

    @State private var nodeStatus = PrereqStatus.checking
    @State private var oppiStatus = PrereqStatus.checking
    @State private var piStatus = PrereqStatus.checking
    @State private var portStatus = PrereqStatus.checking

    private var allPassed: Bool {
        nodeStatus.passed && oppiStatus.passed && piStatus.passed && portStatus.passed
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
                PrereqRow(label: "Oppi CLI", status: oppiStatus)
                PrereqRow(label: "Pi CLI", status: piStatus)
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
        nodeStatus == .checking || oppiStatus == .checking
            || piStatus == .checking || portStatus == .checking
    }

    private func runChecks() {
        nodeStatus = .checking
        oppiStatus = .checking
        piStatus = .checking
        portStatus = .checking

        Task.detached {
            async let node = PrerequisitesView.checkNode()
            async let oppi = PrerequisitesView.checkOppiCLI()
            async let pi = PrerequisitesView.checkCLI(
                named: "pi",
                installCommand: "npm install -g @earendil-works/pi-coding-agent"
            )
            async let port = PrerequisitesView.checkPort(7749)
            let results = await (node, oppi, pi, port)

            await MainActor.run {
                nodeStatus = results.0
                oppiStatus = results.1
                piStatus = results.2
                portStatus = results.3
            }
        }
    }

    // MARK: - Checks

    private static func checkNode() async -> PrereqStatus {
        if let runtimePath = await MainActor.run(body: { ServerProcessManager.resolveRuntimePath() }) {
            let version = await ProcessRunner.version(runtimePath)
            return .passed("Node \(version ?? "")")
        }
        let reason = await MainActor.run(body: { ServerProcessManager.runtimeFailureReason() })
        return .failed(reason)
    }

    private static func checkOppiCLI() async -> PrereqStatus {
        guard let path = await MainActor.run(body: { ServerProcessManager.resolveServerCLIPath() }) else {
            return .failed("Not found — npm install -g oppi-server")
        }
        guard let version = await ProcessRunner.version(path) else {
            return .failed("Found at \(path) but could not get version")
        }
        return .passed(version)
    }

    private static func checkCLI(named name: String, installCommand: String) async -> PrereqStatus {
        guard let path = await ProcessRunner.which(name) else {
            return .failed("Not found — \(installCommand)")
        }
        guard let version = await ProcessRunner.version(path) else {
            return .failed("Found at \(path) but could not get version")
        }
        return .passed(version)
    }

    private nonisolated static func checkPort(_ port: UInt16) async -> PrereqStatus {
        let local = await MainActor.run {
            (dataDir: ServerProcessManager.serverDataDir, baseURL: MacServerLifecycle.defaultBaseURL)
        }
        if let token = MacAPIClient.readOwnerToken(dataDir: local.dataDir),
           let baseURL = local.baseURL {
            let client = MacAPIClient(
                baseURL: baseURL,
                token: token,
                timeoutIntervalForRequest: 1,
                timeoutIntervalForResource: 2
            )
            if await client.checkHealth() {
                return .passed("Oppi server running")
            }
        }

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
