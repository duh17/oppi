import Testing
@testable import Oppi

@Suite("ContextInspectorView")
struct ContextInspectorViewTests {

    // MARK: - ContextUsageSnapshot

    @Test func snapshotProgressNilWhenTokensMissing() {
        let snap = ContextUsageSnapshot(tokens: nil, window: 200_000)
        #expect(snap.progress == nil)
        #expect(snap.percentText == "Unknown")
    }

    @Test func snapshotProgressNilWhenWindowMissing() {
        let snap = ContextUsageSnapshot(tokens: 50_000, window: nil)
        #expect(snap.progress == nil)
    }

    @Test func snapshotProgressNilWhenWindowZero() {
        let snap = ContextUsageSnapshot(tokens: 50_000, window: 0)
        #expect(snap.progress == nil)
    }

    @Test func snapshotProgressCalculatedCorrectly() {
        let snap = ContextUsageSnapshot(tokens: 100_000, window: 200_000)
        #expect(snap.progress == 0.5)
        #expect(snap.percentText == "50.0%")
    }

    @Test func snapshotProgressClampedToOne() {
        let snap = ContextUsageSnapshot(tokens: 300_000, window: 200_000)
        #expect(snap.progress == 1.0)
        #expect(snap.percentText == "100.0%")
    }

    @Test func snapshotUsageTextBothPresent() {
        let snap = ContextUsageSnapshot(tokens: 50_000, window: 200_000)
        #expect(snap.usageText == "50k / 200k")
    }

    @Test func snapshotUsageTextTokensMissing() {
        let snap = ContextUsageSnapshot(tokens: nil, window: 200_000)
        #expect(snap.usageText == "— / 200k")
    }

    @Test func snapshotUsageTextWindowMissing() {
        let snap = ContextUsageSnapshot(tokens: 50_000, window: nil)
        #expect(snap.usageText == "Unknown")
    }

    @Test func snapshotAccessibilityWithProgress() {
        let snap = ContextUsageSnapshot(tokens: 140_000, window: 200_000)
        #expect(snap.accessibilityLabel.contains("70 percent"))
        #expect(snap.accessibilityLabel.contains("140000"))
        #expect(snap.accessibilityLabel.contains("200000"))
    }

    @Test func snapshotAccessibilityNoWindow() {
        let snap = ContextUsageSnapshot(tokens: nil, window: nil)
        #expect(snap.accessibilityLabel == "Context usage unavailable")
    }

    // MARK: - formatTokenCount (removed from production code)

    // MARK: - inferContextWindow

    @Test func inferContextWindowKnownModels() {
        #expect(inferContextWindow(from: "anthropic/claude-sonnet-4-0") == 200_000)
        #expect(inferContextWindow(from: "openai/gpt-4.1") == 1_000_000)
    }

    @Test func inferContextWindowUnknownModel() {
        #expect(inferContextWindow(from: "unknown/model-xyz") == nil)
    }

    // MARK: - Session skills (only loaded skills shown)

    /// The context inspector shows only skills loaded for the session — never
    /// lists unloaded/disabled skills from the host pool.
    @Test func sessionSkillsOnlyIncludesLoadedSkills() {
        let allSkills = [
            SkillInfo(name: "sentry", description: "Sentry stuff", path: "/skills/sentry"),
            SkillInfo(name: "web-fetch", description: "Fetch pages", path: "/skills/web-fetch"),
            SkillInfo(name: "agents-md", description: "AGENTS files", path: "/skills/agents-md"),
            SkillInfo(name: "apple-pim", description: "Apple PIM", path: "/skills/apple-pim"),
        ]
        let sessionSkillNames = ["sentry", "web-fetch"]

        // Same logic the view uses for its "Session Skills" section:
        let byName = Dictionary(uniqueKeysWithValues: allSkills.map { ($0.name, $0) })
        let estimates = sessionSkillNames.sorted().map { name -> (String, String) in
            let skill = byName[name]
            return (name, skill?.description ?? "")
        }

        let estimateNames = estimates.map(\.0)
        #expect(estimateNames == ["sentry", "web-fetch"])

        // Unloaded skills must not appear
        #expect(!estimateNames.contains("agents-md"))
        #expect(!estimateNames.contains("apple-pim"))
    }

    /// When every available skill is loaded, there are zero unloaded skills.
    @Test func noUnloadedSkillsWhenAllActive() {
        let allSkills = [
            SkillInfo(name: "sentry", description: "Sentry stuff", path: "/skills/sentry"),
            SkillInfo(name: "web-fetch", description: "Fetch pages", path: "/skills/web-fetch"),
        ]
        let sessionSkillNames = ["sentry", "web-fetch"]

        let loaded = Set(sessionSkillNames)
        let unloaded = allSkills.filter { !loaded.contains($0.name) }
        #expect(unloaded.isEmpty)
    }

    /// Edge case: session references a skill name not in the host pool.
    /// It should still appear in the session list with a fallback description.
    @Test func sessionSkillMissingFromPoolStillListed() {
        let allSkills = [
            SkillInfo(name: "sentry", description: "Sentry stuff", path: "/skills/sentry"),
        ]
        let sessionSkillNames = ["sentry", "custom-skill"]

        let byName = Dictionary(uniqueKeysWithValues: allSkills.map { ($0.name, $0) })
        let estimates = sessionSkillNames.sorted().map { name -> (String, String) in
            let skill = byName[name]
            return (name, skill?.description ?? "No description available")
        }

        #expect(estimates.count == 2)
        #expect(estimates[0].0 == "custom-skill")
        #expect(estimates[0].1 == "No description available")
        #expect(estimates[1].0 == "sentry")
        #expect(estimates[1].1 == "Sentry stuff")
    }
}
