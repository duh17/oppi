import CryptoKit
import Foundation
import XCTest

enum QAVerificationStatus: String, Codable, Sendable {
    case pass
    case fail
    case unknown
}

enum QAVerificationFailure: Error, CustomStringConvertible {
    case missingTarget(String)
    case ambiguousTarget(String, count: Int)
    case missingScope(String)
    case ambiguousScope(String, count: Int)
    case wrongRole(String)
    case notHittable(String)
    case postcondition(String)
    case unknown(String)
    case evidence(String)

    var status: QAVerificationStatus {
        switch self {
        case .unknown, .evidence:
            return .unknown
        default:
            return .fail
        }
    }

    var description: String {
        switch self {
        case .missingTarget(let target):
            return "Missing unique target \(target)"
        case .ambiguousTarget(let target, let count):
            return "Ambiguous target \(target) (\(count) matches)"
        case .missingScope(let scope):
            return "Missing unique scope \(scope)"
        case .ambiguousScope(let scope, let count):
            return "Ambiguous scope \(scope) (\(count) matches)"
        case .wrongRole(let target):
            return "Wrong role for \(target)"
        case .notHittable(let target):
            return "Target not enabled/hittable \(target)"
        case .postcondition(let message):
            return message
        case .unknown(let message):
            return message
        case .evidence(let message):
            return "Evidence collection failed: \(message)"
        }
    }
}

struct QAVerificationAssertion: Codable, Sendable {
    var name: String
    var required: Bool
    var status: QAVerificationStatus
    var expected: String
    var observed: String
}

struct QAVerificationStep: Codable, Sendable {
    var id: String
    var index: Int
    var op: String
    var target: String?
    var status: QAVerificationStatus
    var startedAt: String
    var endedAt: String
    var durationMs: Int
    var detail: String?
}

struct QAVerificationTiming: Codable, Sendable {
    var observeActionWaitMs: Int
    var modelMs: Int
    var recordingMs: Int
    var wallMs: Int
}

struct QAVerificationCollector: Codable, Sendable {
    var health: String
    var recording: String
    var artifacts: [String]
}

struct QAVerificationSourceBinding: Codable, Sendable {
    var sha: String
    var contentHash: String
}

struct QAVerificationBuiltBinding: Codable, Sendable {
    var testBundlePath: String
    var testBundleSha256: String

    static func current() -> QAVerificationBuiltBinding? {
        let bundle = Bundle(for: QAVerificationExecutor.self)
        guard let url = bundle.executableURL else { return nil }
        do {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let digest = SHA256.hash(data: data)
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            guard !hex.isEmpty else { return nil }
            return QAVerificationBuiltBinding(testBundlePath: url.path, testBundleSha256: hex)
        } catch {
            return nil
        }
    }
}

struct QAVerificationInnerAttempt: Codable, Sendable {
    var status: QAVerificationStatus
    var journeyId: String
    var collectorHealth: String
    var failingReason: String?
}

struct QAVerificationReceiptFile: Codable, Sendable {
    var schema: String
    var status: QAVerificationStatus
    var journeyId: String
    var subject: String
    var driver: String
    var runNonce: String
    var source: QAVerificationSourceBinding
    var built: QAVerificationBuiltBinding
    var runtime: String
    var terminalMirrorExercised: Bool
    var requestedStepIds: [String]
    var requiredAssertionIds: [String]
    var steps: StepCounts
    var assertions: [QAVerificationAssertion]
    var failingStep: FailingStep?
    var timing: QAVerificationTiming
    var collector: QAVerificationCollector
    var mockedBoundaries: [String]
    var semanticsGaps: [String]
    var innerAttempt: QAVerificationInnerAttempt?

    struct StepCounts: Codable, Sendable {
        var requested: Int
        var executed: Int
        var skipped: Int
        var cancelled: Int
        var records: [QAVerificationStep]
    }

    struct FailingStep: Codable, Sendable {
        var index: Int
        var op: String
        var reason: String
    }
}

struct QAVerificationRunBinding: Sendable {
    var runNonce: String
    var sourceSha: String
    var sourceHash: String

    static func fromEnvironment() -> QAVerificationRunBinding? {
        let env = ProcessInfo.processInfo.environment
        func value(_ key: String) -> String? {
            let raw = env[key] ?? env["TEST_RUNNER_\(key)"]
            guard let raw, !raw.isEmpty else { return nil }
            return raw
        }
        guard
            let nonce = value("OPPI_QA_RUN_NONCE"),
            let sha = value("OPPI_QA_SOURCE_SHA"),
            let hash = value("OPPI_QA_SOURCE_HASH")
        else {
            return nil
        }
        return QAVerificationRunBinding(runNonce: nonce, sourceSha: sha, sourceHash: hash)
    }
}

@MainActor
final class QAVerificationReceipt {
    static let schema = "oppi.qa-deterministic.receipt/v1"

    let journeyId: String
    let subject: String
    let driver: String
    let requestedStepIds: [String]
    let requiredAssertionIds: [String]
    let mockedBoundaries: [String]
    var semanticsGaps: [String] = []
    var assertions: [QAVerificationAssertion] = []
    var stepRecords: [QAVerificationStep] = []
    var skippedSteps = 0
    var cancelledSteps = 0
    var modelMs = 0
    var recordingMs = 0
    var collectorHealth = "ok"
    var recordingHealth = "off"
    var artifacts: [String] = []
    var innerAttempt: QAVerificationInnerAttempt?
    private let startedAt = Date()
    private var observeActionWaitMs = 0
    private var failure: QAVerificationFailure?
    private let binding: QAVerificationRunBinding?
    private let built: QAVerificationBuiltBinding?

    init(
        journeyId: String,
        subject: String,
        driver: String,
        requestedStepIds: [String],
        requiredAssertionIds: [String],
        mockedBoundaries: [String]
    ) {
        self.journeyId = journeyId
        self.subject = subject
        self.driver = driver
        self.requestedStepIds = requestedStepIds
        self.requiredAssertionIds = requiredAssertionIds
        self.mockedBoundaries = mockedBoundaries
        self.binding = QAVerificationRunBinding.fromEnvironment()
        self.built = QAVerificationBuiltBinding.current()
        if binding == nil {
            collectorHealth = "failed"
            failure = .unknown("Run/source binding is missing from the test environment")
        } else if built == nil {
            collectorHealth = "failed"
            failure = .unknown("Compiled test-bundle identity could not be hashed")
        }
    }

    func addObserveActionWaitMs(_ ms: Int) {
        observeActionWaitMs += max(0, ms)
    }

    func recordAssertion(
        name: String,
        required: Bool = true,
        status: QAVerificationStatus,
        expected: String,
        observed: String
    ) {
        assertions.append(
            QAVerificationAssertion(
                name: name,
                required: required,
                status: status,
                expected: expected,
                observed: observed
            )
        )
        if required && status != .pass && failure == nil {
            failure = status == .unknown
                ? .unknown("Required assertion \(name) is unknown")
                : .postcondition("Required assertion \(name) failed")
        }
    }

    func recordFailure(_ error: QAVerificationFailure) {
        if failure == nil {
            failure = error
        }
        if error.status == .unknown && collectorHealth == "ok" && isEvidenceFailure(error) {
            collectorHealth = "failed"
        }
    }

    func makeFile() -> QAVerificationReceiptFile {
        let binding = binding ?? QAVerificationRunBinding(runNonce: "", sourceSha: "", sourceHash: "")
        let executed = stepRecords.count
        let skipped = skippedSteps
        let status = resolveStatus(executed: executed, skipped: skipped)
        let failing = failure.map { error in
            let last = stepRecords.last
            return QAVerificationReceiptFile.FailingStep(
                index: last?.index ?? max(0, stepRecords.count - 1),
                op: last?.op ?? "unknown",
                reason: error.description
            )
        }
        return QAVerificationReceiptFile(
            schema: Self.schema,
            status: status,
            journeyId: journeyId,
            subject: subject,
            driver: driver,
            runNonce: binding.runNonce,
            source: QAVerificationSourceBinding(sha: binding.sourceSha, contentHash: binding.sourceHash),
            built: built ?? QAVerificationBuiltBinding(testBundlePath: "", testBundleSha256: ""),
            runtime: "oppi",
            terminalMirrorExercised: false,
            requestedStepIds: requestedStepIds,
            requiredAssertionIds: requiredAssertionIds,
            steps: .init(
                requested: requestedStepIds.count,
                executed: executed,
                skipped: skipped,
                cancelled: cancelledSteps,
                records: stepRecords
            ),
            assertions: assertions,
            failingStep: failing,
            timing: QAVerificationTiming(
                observeActionWaitMs: observeActionWaitMs,
                modelMs: modelMs,
                recordingMs: recordingMs,
                wallMs: Int(Date().timeIntervalSince(startedAt) * 1000)
            ),
            collector: QAVerificationCollector(
                health: collectorHealth,
                recording: recordingHealth,
                artifacts: artifacts
            ),
            mockedBoundaries: mockedBoundaries,
            semanticsGaps: semanticsGaps,
            innerAttempt: innerAttempt
        )
    }

    func write() throws -> URL {
        let file = makeFile()
        let data = try JSONEncoder.qaVerification.encode(file)
        let url = try Self.receiptURL(journeyId: journeyId)
        try data.write(to: url, options: .atomic)
        artifacts.append(url.path)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "qa-receipt-\(journeyId)"
        attachment.lifetime = .keepAlways
        XCTContext.runActivity(named: "QA receipt \(journeyId)") { activity in
            activity.add(attachment)
        }
        return url
    }

    private func resolveStatus(executed: Int, skipped: Int) -> QAVerificationStatus {
        if binding == nil || built == nil || built?.testBundleSha256.isEmpty == true {
            return .unknown
        }
        if requestedStepIds.isEmpty || executed == 0 {
            return .fail
        }
        if skipped > 0 || cancelledSteps > 0 || executed != requestedStepIds.count {
            return failure?.status == .unknown ? .unknown : .fail
        }
        if !recordsMatchCatalog() {
            return failure?.status == .unknown ? .unknown : .fail
        }
        if let failure {
            return failure.status
        }
        if assertions.contains(where: { $0.required && $0.status == .unknown }) {
            return .unknown
        }
        if assertions.contains(where: { $0.required && $0.status != .pass }) {
            return .fail
        }
        let names = assertions.filter(\.required).map(\.name)
        if names != requiredAssertionIds {
            return .fail
        }
        if collectorHealth == "failed" {
            return .unknown
        }
        return .pass
    }

    private func recordsMatchCatalog() -> Bool {
        guard stepRecords.count == requestedStepIds.count else { return false }
        for (index, expectedId) in requestedStepIds.enumerated() {
            let record = stepRecords[index]
            if record.id != expectedId || record.index != index || record.status != .pass {
                return false
            }
        }
        return true
    }

    private func isEvidenceFailure(_ error: QAVerificationFailure) -> Bool {
        if case .evidence = error { return true }
        return false
    }

    static func receiptDirectory() throws -> URL {
        let env = ProcessInfo.processInfo.environment
        let raw = env["OPPI_QA_RECEIPT_DIR"] ?? env["TEST_RUNNER_OPPI_QA_RECEIPT_DIR"]
        let path: String
        if let raw, !raw.isEmpty {
            path = raw
        } else {
            path = NSTemporaryDirectory() + "oppi-qa-receipts"
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func receiptURL(journeyId: String) throws -> URL {
        let safe = journeyId.replacingOccurrences(of: "/", with: "-")
        return try receiptDirectory().appendingPathComponent("\(safe).json")
    }
}

extension JSONEncoder {
    static var qaVerification: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

enum QAVerificationISO8601 {
    static func string(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
