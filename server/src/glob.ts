/**
 * Minimal file-path glob matcher. Replaces minimatch — zero deps.
 *
 * Supports:
 *   *      — match any characters except /
 *   **     — match any characters including / (any depth)
 *   ?      — match any single character except /
 *   {a,b}  — alternation (one level, no nesting)
 *   [abc]  — character class
 *   [!abc] — negated character class
 *   \x     — escape next character
 *
 * Always matches dotfiles (equivalent to minimatch { dot: true }).
 */

export function globMatch(target: string, pattern: string): boolean {
  // Expand {a,b,c} alternations first (non-nested)
  const expanded = expandBraces(pattern);
  return expanded.some((p) => matchOne(target, p));
}

function expandBraces(pattern: string): string[] {
  const open = pattern.indexOf("{");
  if (open === -1) return [pattern];
  const close = pattern.indexOf("}", open);
  if (close === -1) return [pattern]; // unmatched brace, treat literal

  const prefix = pattern.slice(0, open);
  const suffix = pattern.slice(close + 1);
  const alts = pattern.slice(open + 1, close).split(",");

  // Recursively expand in case there are more braces in the suffix
  const results: string[] = [];
  for (const alt of alts) {
    for (const expanded of expandBraces(prefix + alt + suffix)) {
      results.push(expanded);
    }
  }
  return results;
}

function matchOne(target: string, pattern: string): boolean {
  // Convert glob pattern to a sequence of tokens for matching
  let ti = 0; // target index
  let pi = 0; // pattern index

  // For backtracking on ** and *
  let starTi = -1;
  let starPi = -1;
  let dstarTi = -1;
  let dstarPi = -1;

  while (ti < target.length) {
    if (pi < pattern.length && pattern[pi] === "*") {
      if (pi + 1 < pattern.length && pattern[pi + 1] === "*") {
        // ** — match anything including /
        // Skip consecutive *
        while (pi < pattern.length && pattern[pi] === "*") pi++;
        // If ** is followed by /, skip the /
        if (pi < pattern.length && pattern[pi] === "/") pi++;
        dstarTi = ti;
        dstarPi = pi;
        // Reset single-star backtrack since ** is more powerful
        starTi = -1;
        continue;
      }
      // * — match anything except /
      pi++;
      starTi = ti;
      starPi = pi;
      continue;
    }

    if (pi < pattern.length && matchChar(target, ti, pattern, pi)) {
      const advance = charClassLen(pattern, pi);
      ti++;
      pi += advance;
      continue;
    }

    // Mismatch — try backtracking to the most recent wildcard
    if (starTi >= 0) {
      // Backtrack single star: advance the star's match by one (but not past /)
      starTi++;
      if (starTi <= target.length && target[starTi - 1] !== "/") {
        ti = starTi;
        pi = starPi;
        continue;
      }
      starTi = -1; // star exhausted (hit /)
    }

    if (dstarTi >= 0) {
      // Backtrack double star: advance by one (crosses /)
      dstarTi++;
      if (dstarTi <= target.length) {
        ti = dstarTi;
        pi = dstarPi;
        // Reset single-star state
        starTi = -1;
        continue;
      }
    }

    return false;
  }

  // Consume trailing wildcards in pattern
  while (pi < pattern.length && pattern[pi] === "*") pi++;
  // Also consume trailing / after **
  if (pi < pattern.length && pattern[pi] === "/") pi++;
  while (pi < pattern.length && pattern[pi] === "*") pi++;

  return pi === pattern.length;
}

/** Check if target[ti] matches pattern element at pi. Handles ?, [class], \escape, literal. */
function matchChar(target: string, ti: number, pattern: string, pi: number): boolean {
  const tc = target[ti];
  const pc = pattern[pi];

  if (pc === "?") {
    return tc !== "/";
  }

  if (pc === "[") {
    return matchCharClass(tc, pattern, pi);
  }

  if (pc === "\\") {
    return pi + 1 < pattern.length && tc === pattern[pi + 1];
  }

  return tc === pc;
}

/** Return how many chars this pattern element consumes. */
function charClassLen(pattern: string, pi: number): number {
  if (pattern[pi] === "[") {
    const close = pattern.indexOf("]", pi + 1);
    return close === -1 ? 1 : close - pi + 1;
  }
  if (pattern[pi] === "\\") return 2;
  return 1;
}

function matchCharClass(tc: string, pattern: string, pi: number): boolean {
  const close = pattern.indexOf("]", pi + 1);
  if (close === -1) return tc === "["; // unmatched [, treat literal

  let negated = false;
  let i = pi + 1;
  if (pattern[i] === "!" || pattern[i] === "^") {
    negated = true;
    i++;
  }

  let matched = false;
  while (i < close) {
    if (i + 2 < close && pattern[i + 1] === "-") {
      // Range: [a-z]
      if (tc >= pattern[i] && tc <= pattern[i + 2]) matched = true;
      i += 3;
    } else {
      if (tc === pattern[i]) matched = true;
      i++;
    }
  }

  return negated ? !matched : matched;
}
