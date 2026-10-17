/**
 * Exact longest-common-subsequence matching for integer sequences.
 *
 * Linear-space Myers ("An O(ND) Difference Algorithm", 1986): bisect at the
 * middle snake, trim shared prefixes and suffixes, recurse. Lines and word
 * tokens are interned to integers before they reach this module, so every
 * comparison is one integer compare.
 *
 * Guarantees:
 * - Valid: matched elements are equal, and matches are strictly increasing on
 *   both sides, so the unmatched elements are a correct delete/insert script.
 * - Minimal: while `exact` is true, the match count is a longest common
 *   subsequence (edit count is the minimum possible).
 * - Bounded: `maxCost` caps diagonal steps. When a subproblem would exceed it,
 *   that subproblem stays unmatched (still valid, no longer minimal) and
 *   `exact` becomes false. The cap is deterministic, unlike a wall-clock timeout.
 */

export type SequenceMatch = {
  /** 1 where `a[i]` is part of the common subsequence. */
  oldMatched: Uint8Array;
  /** 1 where `b[j]` is part of the common subsequence. */
  newMatched: Uint8Array;
  /** Number of matched pairs. */
  matched: number;
  /** False when `maxCost` cut a subproblem short; the result is then valid but not minimal. */
  exact: boolean;
  /** Diagonal steps spent, for callers that share one budget across many matches. */
  cost: number;
};

/** Default work cap: tens of milliseconds on the server for adversarial inputs. */
export const DEFAULT_SEQUENCE_DIFF_MAX_COST = 20_000_000;

type CostState = { remaining: number; exact: boolean };

export function matchSequences(
  a: ArrayLike<number>,
  b: ArrayLike<number>,
  maxCost: number = DEFAULT_SEQUENCE_DIFF_MAX_COST,
): SequenceMatch {
  const oldMatched = new Uint8Array(a.length);
  const newMatched = new Uint8Array(b.length);
  const state: CostState = { remaining: maxCost, exact: true };
  const matched = matchRange(a, b, 0, a.length, 0, b.length, oldMatched, newMatched, state);
  return {
    oldMatched,
    newMatched,
    matched,
    exact: state.exact,
    cost: maxCost - Math.max(0, state.remaining),
  };
}

function matchRange(
  a: ArrayLike<number>,
  b: ArrayLike<number>,
  aStart: number,
  aEnd: number,
  bStart: number,
  bEnd: number,
  oldMatched: Uint8Array,
  newMatched: Uint8Array,
  state: CostState,
): number {
  let matched = 0;

  while (aStart < aEnd && bStart < bEnd && a[aStart] === b[bStart]) {
    oldMatched[aStart] = 1;
    newMatched[bStart] = 1;
    aStart += 1;
    bStart += 1;
    matched += 1;
  }
  while (aStart < aEnd && bStart < bEnd && a[aEnd - 1] === b[bEnd - 1]) {
    aEnd -= 1;
    bEnd -= 1;
    oldMatched[aEnd] = 1;
    newMatched[bEnd] = 1;
    matched += 1;
  }
  if (aStart === aEnd || bStart === bEnd) return matched;

  const split = middleSnake(a, b, aStart, aEnd, bStart, bEnd, state);
  if (split === null) return matched;

  matched += matchRange(a, b, aStart, split.x, bStart, split.y, oldMatched, newMatched, state);
  matched += matchRange(a, b, split.x, aEnd, split.y, bEnd, oldMatched, newMatched, state);
  return matched;
}

/**
 * Find a point on an optimal edit path roughly halfway through it. Returns
 * null when the ranges share nothing (pure replace) or the cost cap is hit.
 * Both returned halves are strictly smaller than the input range.
 */
function middleSnake(
  a: ArrayLike<number>,
  b: ArrayLike<number>,
  aStart: number,
  aEnd: number,
  bStart: number,
  bEnd: number,
  state: CostState,
): { x: number; y: number } | null {
  const n = aEnd - aStart;
  const m = bEnd - bStart;
  const maxD = Math.ceil((n + m) / 2);
  const offset = maxD;
  const size = 2 * maxD + 2;
  const forward = new Int32Array(size).fill(-1);
  const backward = new Int32Array(size).fill(-1);
  forward[offset + 1] = 0;
  backward[offset + 1] = 0;
  const delta = n - m;
  const checkOnForward = (delta & 1) !== 0;

  // Diagonals that ran off the edit graph are skipped on later rounds.
  let forwardStart = 0;
  let forwardEnd = 0;
  let backwardStart = 0;
  let backwardEnd = 0;

  for (let d = 0; d < maxD; d += 1) {
    state.remaining -= 2 * d + 1;
    if (state.remaining < 0) {
      state.exact = false;
      return null;
    }

    for (let k = -d + forwardStart; k <= d - forwardEnd; k += 2) {
      const index = offset + k;
      const below = forward[index - 1] ?? -1;
      const above = forward[index + 1] ?? -1;
      let x = k === -d || (k !== d && below < above) ? above : below + 1;
      let y = x - k;
      while (x < n && y < m && a[aStart + x] === b[bStart + y]) {
        x += 1;
        y += 1;
      }
      forward[index] = x;
      if (x > n) {
        forwardEnd += 2;
      } else if (y > m) {
        forwardStart += 2;
      } else if (checkOnForward) {
        const backwardX = backward[offset + delta - k] ?? -1;
        if (backwardX !== -1 && x >= n - backwardX) {
          return { x: aStart + x, y: bStart + y };
        }
      }
    }

    for (let k = -d + backwardStart; k <= d - backwardEnd; k += 2) {
      const index = offset + k;
      const below = backward[index - 1] ?? -1;
      const above = backward[index + 1] ?? -1;
      let x = k === -d || (k !== d && below < above) ? above : below + 1;
      let y = x - k;
      while (x < n && y < m && a[aEnd - x - 1] === b[bEnd - y - 1]) {
        x += 1;
        y += 1;
      }
      backward[index] = x;
      if (x > n) {
        backwardEnd += 2;
      } else if (y > m) {
        backwardStart += 2;
      } else if (!checkOnForward) {
        const forwardIndex = offset + delta - k;
        const forwardX = forward[forwardIndex] ?? -1;
        if (forwardX !== -1 && forwardX >= n - x) {
          return { x: aStart + forwardX, y: bStart + offset + forwardX - forwardIndex };
        }
      }
    }
  }

  // No overlap: the ranges share no element.
  return null;
}
