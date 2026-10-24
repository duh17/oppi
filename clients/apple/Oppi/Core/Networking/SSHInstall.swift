import Foundation

// Install & Start: the repo-root `install.sh`, bundled into the app at build
// time, runs over the setup check's signed-in SSH connection. The script is
// the same one `curl … | sh` runs; the contract between them is the
// machine-readable `oppi-install:` lines parsed here. Everything else the
// script prints is for people at a terminal and is ignored.

/// The bundled installer and how it is invoked over SSH.
enum SSHInstallScript {
    /// The script arrives on stdin, so the login shell only has to start `sh`.
    static let command = "/bin/sh -s -- --non-interactive"

    /// `install.sh` from the repo root, copied into the app by `project.yml`.
    static func bundled(in bundle: Bundle = .main) throws(SSHPreflightFailure) -> Data {
        guard let url = bundle.url(forResource: "install", withExtension: "sh"),
              let data = try? Data(contentsOf: url), !data.isEmpty else {
            throw .installerMissing
        }
        return data
    }
}

/// The installer's steps, in the order it runs them.
enum SSHInstallStep: String, CaseIterable, Sendable {
    case node
    case oppi
    case service
    case start
}

/// One `oppi-install:` line.
enum SSHInstallEvent: Equatable, Sendable {
    enum StepStatus: String, Sendable {
        /// `warn`: the step finished, but something needs attention (for
        /// example a Linux service that stops at logout). Setup goes on.
        case begin, ok, skip, warn, fail
    }

    case step(SSHInstallStep, StepStatus, detail: String)
    case done(version: String, port: Int?)
    case error(code: String, detail: String)

    static let prefix = "oppi-install:"

    /// Nil for anything that is not a well-formed progress line: human text,
    /// a step or status this build does not know, or a line missing its key.
    ///
    /// Fields are `key=value` separated by spaces. `detail=` is always last
    /// and runs to the end of the line, so it may contain spaces and `=`.
    static func parse(_ line: Substring) -> SSHInstallEvent? {
        var text = line
        while text.last == "\r" { text.removeLast() }
        guard text.hasPrefix(prefix) else { return nil }
        let body = text.dropFirst(prefix.count).drop { $0 == " " }
        let kind = body.prefix { $0 != " " }
        let fields = Self.fields(body.dropFirst(kind.count))
        switch kind {
        case "done":
            guard let version = fields["version"], !version.isEmpty else { return nil }
            return .done(version: version, port: fields["port"].flatMap { Int($0) })
        case "error":
            guard let code = fields["code"], !code.isEmpty else { return nil }
            return .error(code: code, detail: fields["detail"] ?? "")
        default:
            // A step line starts with its first field, `step=`.
            let stepFields = Self.fields(body)
            guard let step = stepFields["step"].flatMap(SSHInstallStep.init(rawValue:)),
                  let status = stepFields["status"].flatMap(StepStatus.init(rawValue:)) else { return nil }
            return .step(step, status, detail: stepFields["detail"] ?? "")
        }
    }

    private static func fields(_ text: Substring) -> [String: String] {
        var fields: [String: String] = [:]
        var rest = text.drop { $0 == " " }
        while !rest.isEmpty {
            guard let equals = rest.firstIndex(of: "=") else { break }
            let key = String(rest[..<equals])
            let afterEquals = rest[rest.index(after: equals)...]
            if key == "detail" {
                fields[key] = afterEquals.trimmingCharacters(in: .whitespaces)
                break
            }
            let value = afterEquals.prefix { $0 != " " }
            fields[key] = String(value)
            rest = afterEquals.dropFirst(value.count).drop { $0 == " " }
        }
        return fields
    }
}

/// Splits streamed stdout into whole lines. A chunk may end mid-line, and a
/// multi-byte character may straddle two chunks, so bytes wait here until
/// their newline arrives.
struct SSHInstallLineBuffer: Sendable {
    /// A line longer than this is not a progress line (npm can print very
    /// long ones); its bytes are dropped up to the next newline.
    static let maximumLineBytes = 4 * 1024

    private var pending = Data()
    private var discarding = false

    mutating func append(_ chunk: Data) -> [Substring] {
        var lines: [Substring] = []
        var start = chunk.startIndex
        while let newline = chunk[start...].firstIndex(of: UInt8(ascii: "\n")) {
            if !discarding {
                pending.append(chunk[start..<newline])
                if pending.count <= Self.maximumLineBytes {
                    lines.append(Substring(String(decoding: pending, as: UTF8.self)))
                }
            }
            pending.removeAll(keepingCapacity: true)
            discarding = false
            start = chunk.index(after: newline)
        }
        if !discarding {
            pending.append(chunk[start...])
            if pending.count > Self.maximumLineBytes {
                pending.removeAll(keepingCapacity: true)
                discarding = true
            }
        }
        return lines
    }
}

/// What the app knows about a running install, folded from its events.
struct SSHInstallProgress: Equatable, Sendable {
    enum StepState: Equatable, Sendable {
        case pending
        case running(String)
        case finished(String)
        case skipped(String)
        /// Finished with something to fix later; setup continues.
        case warning(String)
        case failed(String)
    }

    struct Completion: Equatable, Sendable {
        let version: String
        let port: Int?
    }

    struct Failure: Equatable, Sendable {
        let code: String
        let detail: String
    }

    private(set) var steps: [SSHInstallStep: StepState] = [:]
    private(set) var completion: Completion?
    private(set) var failure: Failure?

    func state(of step: SSHInstallStep) -> StepState {
        steps[step] ?? .pending
    }

    mutating func apply(_ event: SSHInstallEvent) {
        switch event {
        case .step(let step, let status, let detail):
            switch status {
            case .begin: steps[step] = .running(detail)
            case .ok: steps[step] = .finished(detail)
            case .skip: steps[step] = .skipped(detail)
            case .warn: steps[step] = .warning(detail)
            case .fail: steps[step] = .failed(detail)
            }
        case .done(let version, let port):
            completion = Completion(version: version, port: port)
        case .error(let code, let detail):
            failure = Failure(code: code, detail: detail)
            // The step that was running is the one that stopped, even when
            // the script reported only the error line.
            for (step, state) in steps {
                if case .running = state { steps[step] = .failed(detail) }
            }
        }
    }

    /// How the run ended, from its events and exit status. The contract:
    /// exit 0 only after `done`. An error line wins over everything; a run
    /// that ended any other way without `done` (a crash, an old script, a
    /// non-zero exit after `done`) did not finish.
    func verdict(exitStatus: Int?) -> Result<Completion, SSHPreflightFailure> {
        if let failure {
            return .failure(.installFailed(code: failure.code, detail: failure.detail))
        }
        guard exitStatus == 0, let completion else {
            return .failure(.installIncomplete(exitStatus: exitStatus))
        }
        return .success(completion)
    }
}
