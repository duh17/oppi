import Foundation
import XCTest

/// Strict XCUITest executor: unique scoped targets, collect-then-filter, no firstMatch,
/// no coordinates, no optional passes. Tap/type returning is not a verified outcome.
/// Generic waits do not clear an unconfirmed dispatch.
@MainActor
final class QAVerificationExecutor {
    struct Target: Equatable, CustomStringConvertible {
        enum Kind: Equatable {
            case identifier
            case label
            case value
        }

        var kind: Kind
        var query: String
        var role: XCUIElement.ElementType
        var scopeIdentifier: String?

        var description: String {
            let roleName = qaVerificationRoleName(role)
            let scope = scopeIdentifier.map { " scope=\($0)" } ?? ""
            switch kind {
            case .identifier:
                return "id=\(query) role=\(roleName)\(scope)"
            case .label:
                return "label=\(query) role=\(roleName)\(scope)"
            case .value:
                return "value=\(query) role=\(roleName)\(scope)"
            }
        }

        static func id(_ identifier: String, role: XCUIElement.ElementType, scope: String? = nil) -> Target {
            Target(kind: .identifier, query: identifier, role: role, scopeIdentifier: scope)
        }

        static func label(_ label: String, role: XCUIElement.ElementType, scope: String? = nil) -> Target {
            Target(kind: .label, query: label, role: role, scopeIdentifier: scope)
        }

        static func value(_ value: String, role: XCUIElement.ElementType, scope: String? = nil) -> Target {
            Target(kind: .value, query: value, role: role, scopeIdentifier: scope)
        }
    }

    /// Observable postcondition declared at the mutation. Only a matching wait can confirm it.
    enum Confirmation: Equatable {
        case exists(Target)
        case hittable(Target)
        case gone(Target)
        case value(Target, String)
    }

    let app: XCUIApplication
    let receipt: QAVerificationReceipt
    private var nextIndex = 0
    private var dispatchedUnconfirmed = false
    private var pendingConfirmation: Confirmation?
    private var pendingAlreadySatisfied = false

    init(app: XCUIApplication, receipt: QAVerificationReceipt) {
        self.app = app
        self.receipt = receipt
    }

    var hasUnconfirmedDispatch: Bool { dispatchedUnconfirmed }

    func tap(
        _ target: Target,
        timeout: TimeInterval = 8,
        stepId: String,
        confirming: Confirmation
    ) throws {
        try timed(stepId: stepId, op: "tap", target: target.description) {
            try unlessCanMutate()
            let element = try waitForUnique(target, timeout: timeout, requireHittable: true)
            // The target wait can outlive an unrelated state change. Sample the
            // postcondition only after it finishes, immediately before dispatch.
            let already = try isSatisfied(confirming)
            beginDispatch(confirming: confirming, alreadySatisfied: already)
            element.tap()
        }
    }

    func type(
        _ target: Target,
        text: String,
        timeout: TimeInterval = 8,
        stepId: String,
        confirming: Confirmation
    ) throws {
        try timed(stepId: stepId, op: "type", target: target.description) {
            try unlessCanMutate()
            let element = try waitForUnique(target, timeout: timeout, requireHittable: true)
            let already = try isSatisfied(confirming)
            beginDispatch(confirming: confirming, alreadySatisfied: already)
            element.tap()
            let focused = waitUntil(timeout: 3) {
                (element.value(forKey: "hasKeyboardFocus") as? Bool) == true
            }
            guard focused else {
                throw QAVerificationFailure.postcondition("Keyboard focus was not established before typing \(target)")
            }
            element.typeText(text)
        }
    }

    func waitExists(_ target: Target, timeout: TimeInterval, stepId: String) throws {
        _ = try timed(stepId: stepId, op: "waitExists", target: target.description) {
            let element = try waitForUnique(
                target,
                timeout: timeout,
                requireHittable: false,
                reconciling: isPending(.exists(target))
            )
            try considerConfirmation(.exists(target))
            return element
        }
    }

    func waitHittable(_ target: Target, timeout: TimeInterval, stepId: String) throws {
        _ = try timed(stepId: stepId, op: "waitHittable", target: target.description) {
            let element = try waitForUnique(
                target,
                timeout: timeout,
                requireHittable: true,
                reconciling: isPending(.hittable(target))
            )
            try considerConfirmation(.hittable(target))
            return element
        }
    }

    func waitGone(_ target: Target, timeout: TimeInterval, stepId: String) throws {
        try timed(stepId: stepId, op: "waitGone", target: target.description) {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                let matches = try existingMatches(target)
                if matches.isEmpty {
                    try considerConfirmation(.gone(target))
                    return
                }
                if matches.count > 1 {
                    throw QAVerificationFailure.ambiguousTarget(target.description, count: matches.count)
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
            if isPending(.gone(target)) && dispatchedUnconfirmed {
                throw QAVerificationFailure.unknown("Could not reconcile \(target) gone after unconfirmed dispatch")
            }
            throw QAVerificationFailure.postcondition("\(target) still present after \(timeout)s")
        }
    }

    func readValue(_ target: Target) throws -> String {
        let matches = try existingMatches(target)
        if matches.isEmpty {
            throw QAVerificationFailure.missingTarget(target.description)
        }
        if matches.count > 1 {
            throw QAVerificationFailure.ambiguousTarget(target.description, count: matches.count)
        }
        guard let value = matches[0].value as? String else {
            throw QAVerificationFailure.postcondition("\(target) has no string value")
        }
        return value
    }

    func captureEvidence(name: String, directory overrideDirectory: URL? = nil, stepId: String? = nil) throws {
        let work = {
            let directory: URL
            do {
                directory = try overrideDirectory ?? QAVerificationReceipt.receiptDirectory()
            } catch {
                self.receipt.collectorHealth = "failed"
                throw QAVerificationFailure.evidence(error.localizedDescription)
            }
            let pngURL = directory.appendingPathComponent("\(self.receipt.journeyId)-\(name).png")
            let treeURL = directory.appendingPathComponent("\(self.receipt.journeyId)-\(name).txt")
            let screenshot = self.app.screenshot()
            do {
                try screenshot.pngRepresentation.write(to: pngURL, options: .atomic)
                try self.app.debugDescription.write(to: treeURL, atomically: true, encoding: .utf8)
            } catch {
                self.receipt.collectorHealth = "failed"
                throw QAVerificationFailure.evidence(error.localizedDescription)
            }
            self.receipt.artifacts.append(pngURL.path)
            self.receipt.artifacts.append(treeURL.path)
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            XCTContext.runActivity(named: "evidence \(name)") { activity in
                activity.add(attachment)
            }
        }
        if let stepId {
            try timed(stepId: stepId, op: "evidence", target: name, work)
        } else {
            try work()
        }
    }

    private func unlessCanMutate() throws {
        if dispatchedUnconfirmed {
            throw QAVerificationFailure.unknown("Previous dispatch is unconfirmed; refusing another mutation")
        }
    }

    private func beginDispatch(confirming: Confirmation, alreadySatisfied: Bool) {
        dispatchedUnconfirmed = true
        pendingConfirmation = confirming
        pendingAlreadySatisfied = alreadySatisfied
    }

    private func confirmDispatch() {
        dispatchedUnconfirmed = false
        pendingConfirmation = nil
        pendingAlreadySatisfied = false
    }

    private func isPending(_ observed: Confirmation) -> Bool {
        pendingConfirmation == observed
    }

    private func considerConfirmation(_ observed: Confirmation) throws {
        guard dispatchedUnconfirmed, pendingConfirmation == observed else { return }
        if pendingAlreadySatisfied {
            throw QAVerificationFailure.unknown(
                "Declared postcondition was already true before dispatch; this wait does not confirm it"
            )
        }
        confirmDispatch()
    }

    private func isSatisfied(_ confirmation: Confirmation) throws -> Bool {
        switch confirmation {
        case .exists(let target):
            let matches = try existingMatches(target)
            if matches.count > 1 {
                throw QAVerificationFailure.ambiguousTarget(target.description, count: matches.count)
            }
            return matches.count == 1
        case .hittable(let target):
            let matches = try existingMatches(target)
            if matches.count > 1 {
                throw QAVerificationFailure.ambiguousTarget(target.description, count: matches.count)
            }
            guard let element = matches.first else { return false }
            return element.isEnabled && element.isHittable
        case .gone(let target):
            let matches = try existingMatches(target)
            if matches.count > 1 {
                throw QAVerificationFailure.ambiguousTarget(target.description, count: matches.count)
            }
            return matches.isEmpty
        case .value(let target, let expected):
            let matches = try existingMatches(target)
            if matches.count > 1 {
                throw QAVerificationFailure.ambiguousTarget(target.description, count: matches.count)
            }
            guard let element = matches.first else { return false }
            return (element.value as? String) == expected
        }
    }

    private func waitForUnique(
        _ target: Target,
        timeout: TimeInterval,
        requireHittable: Bool,
        reconciling: Bool = false
    ) throws -> XCUIElement {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: QAVerificationFailure = .missingTarget(target.description)
        while Date() < deadline {
            do {
                return try unique(target, requireHittable: requireHittable)
            } catch let error as QAVerificationFailure {
                if case .ambiguousTarget = error { throw error }
                if case .ambiguousScope = error { throw error }
                if case .missingScope = error { throw error }
                lastError = error
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        if reconciling && dispatchedUnconfirmed {
            throw QAVerificationFailure.unknown(
                "Could not reconcile \(target) after unconfirmed dispatch: \(lastError)"
            )
        }
        throw lastError
    }

    private func unique(_ target: Target, requireHittable: Bool) throws -> XCUIElement {
        guard !target.query.isEmpty else {
            throw QAVerificationFailure.missingTarget(target.description)
        }
        let matches = try existingMatches(target)
        if matches.isEmpty {
            throw QAVerificationFailure.missingTarget(target.description)
        }
        if matches.count > 1 {
            throw QAVerificationFailure.ambiguousTarget(target.description, count: matches.count)
        }
        let element = matches[0]
        if requireHittable && (!element.isEnabled || !element.isHittable) {
            throw QAVerificationFailure.notHittable(target.description)
        }
        return element
    }

    private func existingMatches(_ target: Target) throws -> [XCUIElement] {
        let scope = try resolveScope(target.scopeIdentifier)
        let query: XCUIElementQuery
        switch target.kind {
        case .identifier:
            query = scope.descendants(matching: .any).matching(identifier: target.query)
        case .label:
            query = scope.descendants(matching: .any).matching(NSPredicate(format: "label == %@", target.query))
        case .value:
            query = scope.descendants(matching: .any).matching(NSPredicate(format: "value == %@", target.query))
        }
        let total = query.count
        if total > 32 {
            throw QAVerificationFailure.ambiguousTarget(target.description, count: total)
        }
        var matches: [XCUIElement] = []
        for index in 0..<total {
            let element = query.element(boundBy: index)
            guard element.exists else { continue }
            if target.role != .any && element.elementType != target.role {
                continue
            }
            matches.append(element)
        }
        return matches
    }

    private func resolveScope(_ identifier: String?) throws -> XCUIElement {
        guard let identifier else { return app }
        if identifier.isEmpty {
            throw QAVerificationFailure.missingScope("<empty>")
        }
        let query = app.descendants(matching: .any).matching(identifier: identifier)
        let total = query.count
        var matches: [XCUIElement] = []
        let limit = min(total, 32)
        for index in 0..<limit {
            let element = query.element(boundBy: index)
            if element.exists {
                matches.append(element)
            }
        }
        if total > 32 {
            throw QAVerificationFailure.ambiguousScope(identifier, count: total)
        }
        if matches.isEmpty {
            throw QAVerificationFailure.missingScope(identifier)
        }
        if matches.count > 1 {
            throw QAVerificationFailure.ambiguousScope(identifier, count: matches.count)
        }
        return matches[0]
    }

    private func waitUntil(timeout: TimeInterval, _ predicate: () -> Bool) -> Bool {
        if predicate() { return true }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            if predicate() { return true }
        }
        return predicate()
    }

    private func timed<T>(stepId: String, op: String, target: String?, _ body: () throws -> T) throws -> T {
        let index = nextIndex
        nextIndex += 1
        let start = Date()
        do {
            let value = try body()
            let ended = Date()
            let duration = Int(ended.timeIntervalSince(start) * 1000)
            receipt.addObserveActionWaitMs(duration)
            receipt.stepRecords.append(
                QAVerificationStep(
                    id: stepId,
                    index: index,
                    op: op,
                    target: target,
                    status: .pass,
                    startedAt: QAVerificationISO8601.string(start),
                    endedAt: QAVerificationISO8601.string(ended),
                    durationMs: duration,
                    detail: dispatchedUnconfirmed ? "dispatched-unconfirmed" : nil
                )
            )
            return value
        } catch let error as QAVerificationFailure {
            let ended = Date()
            let duration = Int(ended.timeIntervalSince(start) * 1000)
            receipt.addObserveActionWaitMs(duration)
            receipt.stepRecords.append(
                QAVerificationStep(
                    id: stepId,
                    index: index,
                    op: op,
                    target: target,
                    status: error.status,
                    startedAt: QAVerificationISO8601.string(start),
                    endedAt: QAVerificationISO8601.string(ended),
                    durationMs: duration,
                    detail: error.description
                )
            )
            receipt.recordFailure(error)
            throw error
        }
    }
}

func qaVerificationRoleName(_ role: XCUIElement.ElementType) -> String {
    switch role {
    case .button: return "button"
    case .textField: return "textField"
    case .textView: return "textView"
    case .staticText: return "staticText"
    case .searchField: return "searchField"
    case .other: return "other"
    case .any: return "any"
    default: return "type-\(role.rawValue)"
    }
}
