export type SeededRng = () => number;

export function mulberry32(seed: number): SeededRng {
  let state = seed >>> 0;
  return () => {
    state += 0x6d2b79f5;
    let t = Math.imul(state ^ (state >>> 15), state | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export function formatSeededRepro(seed: number, steps: string[]): string {
  return `seed=${seed}; steps=${steps.join(" -> ")}`;
}
