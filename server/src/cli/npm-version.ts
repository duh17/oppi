type SemanticVersion = {
  major: number;
  minor: number;
  patch: number;
  prerelease: string[];
};

function parseSemanticVersion(raw: string): SemanticVersion | null {
  const match = raw
    .trim()
    .replace(/^[vV]/, "")
    .match(/^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$/);
  if (!match) return null;

  return {
    major: Number(match[1]),
    minor: Number(match[2]),
    patch: Number(match[3]),
    prerelease: match[4]?.split(".") ?? [],
  };
}

function comparePrerelease(left: string[], right: string[]): number {
  if (left.length === 0 || right.length === 0) {
    if (left.length === right.length) return 0;
    return left.length === 0 ? 1 : -1;
  }

  const length = Math.max(left.length, right.length);
  for (let index = 0; index < length; index += 1) {
    const leftPart = left[index];
    const rightPart = right[index];
    if (leftPart === undefined) return -1;
    if (rightPart === undefined) return 1;
    if (leftPart === rightPart) continue;

    const leftNumeric = /^\d+$/.test(leftPart);
    const rightNumeric = /^\d+$/.test(rightPart);
    if (leftNumeric && rightNumeric) {
      return Number(leftPart) - Number(rightPart);
    }
    if (leftNumeric !== rightNumeric) {
      return leftNumeric ? -1 : 1;
    }
    return leftPart < rightPart ? -1 : 1;
  }
  return 0;
}

/** Compare npm package versions using SemVer precedence. */
export function compareNpmVersions(leftRaw: string, rightRaw: string): number {
  const left = parseSemanticVersion(leftRaw);
  const right = parseSemanticVersion(rightRaw);
  if (!left || !right) {
    throw new Error(`Invalid semantic version comparison: ${leftRaw} and ${rightRaw}`);
  }

  for (const key of ["major", "minor", "patch"] as const) {
    if (left[key] !== right[key]) return left[key] - right[key];
  }
  return comparePrerelease(left.prerelease, right.prerelease);
}

export function isNpmVersionNewer(candidate: string, current: string): boolean {
  return compareNpmVersions(candidate, current) > 0;
}
