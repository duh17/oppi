import Foundation

func waitForTestCondition(
    timeoutMs: Int = 1_000,
    pollMs: Int = 20,
    _ predicate: @escaping @Sendable () async -> Bool
) async -> Bool {
    let sanitizedPollMs = max(1, pollMs)
    let attempts = max(1, timeoutMs / sanitizedPollMs)

    for _ in 0..<attempts {
        if await predicate() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(sanitizedPollMs))
    }

    return await predicate()
}
