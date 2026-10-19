import Foundation

/// Exact longest-common-subsequence matching for integer sequences.
///
/// A line-for-line port of the server's `server/src/sequence-diff.ts`, so
/// word highlights the client computes match server diffs, ties included.
/// Linear-space Myers ("An O(ND) Difference Algorithm", 1986): trim shared
/// prefixes and suffixes, bisect at the middle snake, recurse.
///
/// - Valid: matched elements are equal and strictly increasing on both sides.
/// - Minimal: while `exact` is true, the match is a longest common subsequence.
/// - Bounded: `maxCost` caps diagonal steps (roughly the square of the edit
///   count, not the line length). A subproblem past the cap stays unmatched
///   and `exact` becomes false.
enum SequenceDiff {
    struct Match {
        var oldMatched: [Bool]
        var newMatched: [Bool]
        /// False when `maxCost` cut a subproblem short.
        var exact: Bool
        /// Diagonal steps spent, for callers that share one budget.
        var cost: Int
    }

    static func match(_ a: [Int], _ b: [Int], maxCost: Int) -> Match {
        var matcher = Matcher(a: a, b: b, remaining: maxCost)
        matcher.matchRange(aStart: 0, aEnd: a.count, bStart: 0, bEnd: b.count)
        return Match(
            oldMatched: matcher.oldMatched,
            newMatched: matcher.newMatched,
            exact: matcher.exact,
            cost: maxCost - max(0, matcher.remaining)
        )
    }

    private struct Matcher {
        let a: [Int]
        let b: [Int]
        var remaining: Int
        var exact = true
        var oldMatched: [Bool]
        var newMatched: [Bool]

        init(a: [Int], b: [Int], remaining: Int) {
            self.a = a
            self.b = b
            self.remaining = remaining
            oldMatched = Array(repeating: false, count: a.count)
            newMatched = Array(repeating: false, count: b.count)
        }

        mutating func matchRange(aStart: Int, aEnd: Int, bStart: Int, bEnd: Int) {
            var aStart = aStart, aEnd = aEnd, bStart = bStart, bEnd = bEnd
            while aStart < aEnd, bStart < bEnd, a[aStart] == b[bStart] {
                oldMatched[aStart] = true
                newMatched[bStart] = true
                aStart += 1
                bStart += 1
            }
            while aStart < aEnd, bStart < bEnd, a[aEnd - 1] == b[bEnd - 1] {
                aEnd -= 1
                bEnd -= 1
                oldMatched[aEnd] = true
                newMatched[bEnd] = true
            }
            guard aStart < aEnd, bStart < bEnd,
                  let split = middleSnake(aStart: aStart, aEnd: aEnd, bStart: bStart, bEnd: bEnd) else { return }
            matchRange(aStart: aStart, aEnd: split.x, bStart: bStart, bEnd: split.y)
            matchRange(aStart: split.x, aEnd: aEnd, bStart: split.y, bEnd: bEnd)
        }

        /// A point on an optimal edit path about halfway through it, or nil
        /// when the ranges share nothing or the cost cap is hit. Both halves
        /// are strictly smaller than the input range.
        mutating func middleSnake(aStart: Int, aEnd: Int, bStart: Int, bEnd: Int) -> (x: Int, y: Int)? {
            let n = aEnd - aStart
            let m = bEnd - bStart
            let maxD = (n + m + 1) / 2
            let offset = maxD
            let size = 2 * maxD + 2
            var forward = [Int](repeating: -1, count: size)
            var backward = [Int](repeating: -1, count: size)
            forward[offset + 1] = 0
            backward[offset + 1] = 0
            let delta = n - m
            let checkOnForward = delta & 1 != 0

            func value(_ array: [Int], _ index: Int) -> Int {
                index >= 0 && index < array.count ? array[index] : -1
            }

            // Diagonals that ran off the edit graph are skipped on later rounds.
            var forwardStart = 0, forwardEnd = 0, backwardStart = 0, backwardEnd = 0

            for d in 0..<maxD {
                remaining -= 2 * d + 1
                if remaining < 0 {
                    exact = false
                    return nil
                }

                for k in stride(from: -d + forwardStart, through: d - forwardEnd, by: 2) {
                    let index = offset + k
                    let below = value(forward, index - 1)
                    let above = value(forward, index + 1)
                    var x = k == -d || (k != d && below < above) ? above : below + 1
                    var y = x - k
                    while x < n, y < m, a[aStart + x] == b[bStart + y] {
                        x += 1
                        y += 1
                    }
                    forward[index] = x
                    if x > n {
                        forwardEnd += 2
                    } else if y > m {
                        forwardStart += 2
                    } else if checkOnForward {
                        let backwardX = value(backward, offset + delta - k)
                        if backwardX != -1, x >= n - backwardX {
                            return (aStart + x, bStart + y)
                        }
                    }
                }

                for k in stride(from: -d + backwardStart, through: d - backwardEnd, by: 2) {
                    let index = offset + k
                    let below = value(backward, index - 1)
                    let above = value(backward, index + 1)
                    var x = k == -d || (k != d && below < above) ? above : below + 1
                    var y = x - k
                    while x < n, y < m, a[aEnd - x - 1] == b[bEnd - y - 1] {
                        x += 1
                        y += 1
                    }
                    backward[index] = x
                    if x > n {
                        backwardEnd += 2
                    } else if y > m {
                        backwardStart += 2
                    } else if !checkOnForward {
                        let forwardIndex = offset + delta - k
                        let forwardX = value(forward, forwardIndex)
                        if forwardX != -1, forwardX >= n - x {
                            return (aStart + forwardX, bStart + offset + forwardX - forwardIndex)
                        }
                    }
                }
            }
            // No overlap: the ranges share no element.
            return nil
        }
    }
}
