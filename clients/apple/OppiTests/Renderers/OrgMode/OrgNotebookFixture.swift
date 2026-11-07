// swiftlint:disable todo - Org-mode headline keyword examples, not unfinished work

/// Org files written the way an agent notebook is: custom `#+TODO:` states,
/// planning lines, `:ID:` drawers, progress cookies, and links between files.
/// Neutral sample data; paths use a made-up home directory.
enum OrgNotebookFixture {
    static let projectPath = "/Users/alex/notebook/projects/oppi.org"
    static let sourceDirectory = "/Users/alex/notebook/projects"

    static let knownID = "3f2a9c1e-7b64-4d0a-9d1e-0c5a2b7e8f10"

    static let project = """
    #+TITLE: Oppi project
    #+TODO: TODO NEXT WAIT | DONE CANCELLED

    * NEXT [#A] Ship Org rendering [1/3] :oppi:ios:
    SCHEDULED: <2026-11-11 Wed> DEADLINE: <2026-11-13 Fri 17:00>
    :PROPERTIES:
    :ID: \(knownID)
    :END:
    Parser, converter and reader. Check [[id:\(knownID)][this task]], the [[file:../notes/release.org::*Checklist][release checklist]] and [[id:ffffffff-0000-0000-0000-000000000000][a note elsewhere]].
    - [X] Parse planning lines
    - [ ] Render progress cookies [0/2]
    - [ ] Open file links
    ** DONE Draft the brief :oppi:
    CLOSED: [2026-11-06 Fri 14:00]
    ** WAIT Device check [40%]
    SCHEDULED: <2026-11-12 Thu +1w>
    ** CANCELLED Retire the old extension
    CLOSED: [2026-11-05 Thu 09:30]
    * Notes
    - No iPhone dev install :until:2026-11-11:
    - See [[file:../notes/release.org][release notes]], [[https://example.com][the web]] and [[*Ship Org rendering][the task above]].
    """
}
