/**
 * Async mutex per key. Calls for the same key run one at a time in arrival order; different keys
 * run concurrently. The lock is released when `fn` settles, including when it throws.
 *
 * A key's entry exists only while someone holds or waits for it, so the map never outgrows the
 * set of in-flight operations. Deleting an entry that still has a waiter would let the next caller
 * start a fresh chain alongside the holder, hence the reference count.
 */
export class KeyedMutex {
  private readonly entries = new Map<string, { tail: Promise<void>; refs: number }>();

  async withLock<T>(key: string, fn: () => Promise<T>): Promise<T> {
    let entry = this.entries.get(key);
    if (!entry) {
      entry = { tail: Promise.resolve(), refs: 0 };
      this.entries.set(key, entry);
    }
    entry.refs += 1;
    const previous = entry.tail;
    let release!: () => void;
    entry.tail = new Promise<void>((resolve) => {
      release = resolve;
    });
    try {
      await previous;
      return await fn();
    } finally {
      release();
      entry.refs -= 1;
      if (entry.refs === 0) this.entries.delete(key);
    }
  }
}
