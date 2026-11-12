import { setFlagsFromString } from "node:v8";
import { runInNewContext } from "node:vm";

/** A full, synchronous collection: Bun.gc(true) under Bun, V8's exposed gc() under Node. */
function fullGc(): () => void {
  const bun = (globalThis as { Bun?: { gc(force: boolean): void } }).Bun;
  if (bun) return () => bun.gc(true);
  setFlagsFromString("--expose-gc");
  return runInNewContext("gc") as () => void;
}

const gc = fullGc();

/** Whether `ref` is collected after a few full collections, with turns between them for finalizers. */
export async function collected(ref: WeakRef<object>): Promise<boolean> {
  for (let round = 0; round < 10 && ref.deref() !== undefined; round++) {
    await new Promise((resolve) => setTimeout(resolve, 0));
    gc();
  }
  return ref.deref() === undefined;
}
