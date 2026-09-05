/** Sliding-window counter with idle-key expiry. */

export class SourceRateLimiter {
  private readonly hits = new Map<string, number[]>();

  constructor(
    private readonly windowMs: number,
    private readonly limit: number,
  ) {}

  tooMany(key: string, now = Date.now()): boolean {
    this.prune(now);
    const windowStart = now - this.windowMs;
    const recent = (this.hits.get(key) ?? []).filter((timestamp) => timestamp >= windowStart);
    if (recent.length >= this.limit) {
      this.hits.set(key, recent);
      return true;
    }
    recent.push(now);
    this.hits.set(key, recent);
    return false;
  }

  prune(now = Date.now()): void {
    const windowStart = now - this.windowMs;
    for (const [key, timestamps] of this.hits) {
      const recent = timestamps.filter((timestamp) => timestamp >= windowStart);
      if (recent.length === 0) this.hits.delete(key);
      else this.hits.set(key, recent);
    }
  }
}
