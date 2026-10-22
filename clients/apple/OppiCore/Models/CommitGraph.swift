import Foundation

/// Response from GET /workspaces/:id/git/graph: a page of HEAD and every local
/// branch, newest first in topological order (a commit before its parents).
struct CommitGraphResponse: Codable, Sendable {
    let commits: [CommitGraphCommit]
    let hasMore: Bool
    /// The repository's checkouts; the first page only.
    let worktrees: [WorkspaceWorktree]?
}

struct CommitGraphCommit: Codable, Sendable, Equatable, Identifiable {
    /// Full SHA.
    let sha: String
    /// Abbreviated SHA, for display and commit detail requests.
    let shortSha: String
    /// Full SHAs, first parent first.
    let parents: [String]
    let message: String
    /// ISO timestamp
    let date: String
    let refs: [CommitGraphRef]

    var id: String { sha }

    /// The queried checkout has this commit checked out.
    var isHead: Bool { refs.contains { $0.kind == .head || $0.isHead == true } }

    var summary: GitCommitSummary { GitCommitSummary(sha: shortSha, message: message, date: date) }
}

struct CommitGraphRef: Codable, Sendable, Equatable, Hashable {
    enum Kind: String, Codable, Sendable {
        case branch
        case remote
        case tag
        /// A detached HEAD.
        case head
    }

    let kind: Kind
    let name: String
    /// The branch the queried checkout has out (`HEAD -> name`).
    let isHead: Bool?
}

// MARK: - Lanes

/// One commit's row of the graph: the lane its dot sits in and the lines
/// through the row, in lane columns. Lines meet the rows above and below at
/// the same column, so stacked rows draw one continuous graph.
struct CommitGraphRow: Equatable, Sendable {
    let commit: CommitGraphCommit
    /// The dot's lane.
    let column: Int
    /// The dot's lane comes down from the row above (a child drew it); false
    /// for a branch tip.
    let continuesFromAbove: Bool
    /// Lanes that pass the row without touching the dot.
    let passing: [Int]
    /// Lanes the dot's lines run to at the row's bottom: the first parent's,
    /// then each merged parent's. A lane other than `column` bends there.
    let outgoing: [Int]
}

/// Assigns lanes to commits in topological order, like `git log --graph`:
/// each lane waits for one commit. A parent another lane already waits for is
/// joined, not given a second lane, so branches forked from one commit meet as
/// soon as their own commits end, and the graph stays a few lanes wide.
struct CommitGraphLayout: Equatable, Sendable {
    let rows: [CommitGraphRow]
    /// The most lanes any row uses.
    let laneCount: Int

    init(commits: [CommitGraphCommit]) {
        var lanes: [String?] = []
        var rows: [CommitGraphRow] = []
        rows.reserveCapacity(commits.count)
        var laneCount = 0

        func freeLane() -> Int {
            if let index = lanes.firstIndex(where: { $0 == nil }) { return index }
            lanes.append(nil)
            return lanes.count - 1
        }

        for commit in commits {
            let waiting = lanes.firstIndex { $0 == commit.sha }
            let column = waiting ?? freeLane()
            var passing: [Int] = []
            for (index, sha) in lanes.enumerated() where sha != nil && index != column {
                passing.append(index)
            }
            lanes[column] = nil

            var outgoing: [Int] = []
            for parent in commit.parents {
                if let joined = lanes.firstIndex(where: { $0 == parent }) {
                    outgoing.append(joined)
                } else {
                    // The first parent keeps the dot's lane while it is free.
                    let lane = lanes[column] == nil && outgoing.isEmpty ? column : freeLane()
                    lanes[lane] = parent
                    outgoing.append(lane)
                }
            }

            laneCount = max(laneCount, lanes.count, column + 1)
            while lanes.last == .some(nil) { lanes.removeLast() }
            rows.append(CommitGraphRow(
                commit: commit,
                column: column,
                continuesFromAbove: waiting != nil,
                passing: passing,
                outgoing: outgoing
            ))
        }
        self.rows = rows
        self.laneCount = laneCount
    }
}
