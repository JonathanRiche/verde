export class FixedWindowRateLimiter {
  readonly #entries = new Map<string, { count: number; windowStartedAt: number }>();

  constructor(
    readonly maximum: number,
    readonly windowMs: number,
    readonly maximumKeys = 10_000,
  ) {}

  allow(key: string, now = Date.now()): boolean {
    const existing = this.#entries.get(key);
    if (existing === undefined || now - existing.windowStartedAt >= this.windowMs) {
      this.ensureCapacity(now);
      this.#entries.set(key, { count: 1, windowStartedAt: now });
      return true;
    }
    if (existing.count >= this.maximum) return false;
    existing.count += 1;
    return true;
  }

  private ensureCapacity(now: number): void {
    if (this.#entries.size < this.maximumKeys) return;
    for (const [key, entry] of this.#entries) {
      if (now - entry.windowStartedAt >= this.windowMs) this.#entries.delete(key);
    }
    if (this.#entries.size < this.maximumKeys) return;
    const oldest = this.#entries.keys().next().value as string | undefined;
    if (oldest !== undefined) this.#entries.delete(oldest);
  }
}
