import { setFlagsFromString } from "node:v8";
import { runInNewContext } from "node:vm";

setFlagsFromString("--expose-gc");
const gc = runInNewContext("gc") as () => void;

/** Whether `ref` is collected after a few full collections, with turns between them for finalizers. */
export async function collected(ref: WeakRef<object>): Promise<boolean> {
  for (let round = 0; round < 10 && ref.deref() !== undefined; round++) {
    await new Promise((resolve) => setTimeout(resolve, 0));
    gc();
  }
  return ref.deref() === undefined;
}
