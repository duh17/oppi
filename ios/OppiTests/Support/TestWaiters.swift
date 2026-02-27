import Foundation

func waitForTestCondition(
    timeout: Duration = .seconds(1),
    poll: Duration = .milliseconds(20),
    _ predicate: @escaping @Sendable () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)

    while ContinuousClock.now < deadline {
        if await predicate() {
            return true
        }
        await Task.yield()
        try? await Task.sleep(for: poll)
    }

    return await predicate()
}

func waitForTestCondition(
    timeoutMs: Int,
    pollMs: Int = 20,
    _ predicate: @escaping @Sendable () async -> Bool
) async -> Bool {
    await waitForTestCondition(
        timeout: .milliseconds(timeoutMs),
        poll: .milliseconds(max(1, pollMs)),
        predicate
    )
}

@MainActor
func waitForMainActorCondition(
    timeout: Duration = .seconds(1),
    poll: Duration = .milliseconds(20),
    _ predicate: () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)

    while ContinuousClock.now < deadline {
        if predicate() {
            return true
        }
        await Task.yield()
        try? await Task.sleep(for: poll)
    }

    return predicate()
}

@MainActor
func waitForMainActorConditionToStayTrue(
    for duration: Duration,
    poll: Duration = .milliseconds(20),
    _ predicate: () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: duration)

    while ContinuousClock.now < deadline {
        if !predicate() {
            return false
        }
        await Task.yield()
        try? await Task.sleep(for: poll)
    }

    return predicate()
}
