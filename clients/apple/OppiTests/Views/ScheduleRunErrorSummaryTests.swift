import Testing
@testable import Oppi

@Suite("Schedule run error summary")
struct ScheduleRunErrorSummaryTests {
    @Test func bareCodeIsPrettified() {
        #expect(ScheduleManagementView.runErrorSummary("agent_extensions_unavailable") == "agent extensions unavailable")
    }

    @Test func detailPassesThroughUnchanged() {
        let id = "extension_3f2a" + String(repeating: "b", count: 50)
        #expect(
            ScheduleManagementView.runErrorSummary("agent_extensions_unavailable: \(id)")
                == "agent extensions unavailable: \(id)"
        )
        #expect(
            ScheduleManagementView.runErrorSummary("agent_skills_unavailable: /Users/x/skills/my_skill/SKILL.md, /a_b/SKILL.md")
                == "agent skills unavailable: /Users/x/skills/my_skill/SKILL.md, /a_b/SKILL.md"
        )
        // Only the first colon splits; later colons stay in the detail.
        #expect(
            ScheduleManagementView.runErrorSummary("Schedule run lease was lost: run_a:b")
                == "Schedule run lease was lost: run_a:b"
        )
    }

    @Test func approvalRequiredHidesTheRawCode() {
        let summary = ScheduleManagementView.runErrorSummary("approval_required_noninteractive: bash")
        #expect(summary?.contains("approval_required_noninteractive") == false)
        #expect(summary?.contains("bash") == false)
    }

    @Test func emptyOrMissingIsNil() {
        #expect(ScheduleManagementView.runErrorSummary(nil) == nil)
        #expect(ScheduleManagementView.runErrorSummary("") == nil)
    }
}
