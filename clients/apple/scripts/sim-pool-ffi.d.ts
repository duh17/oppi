/** Installed bun:ffi surface used by sim-pool-lock and sim-pool-clone. Not a substitute for @types/node. */
declare module "bun:ffi" {
  export const FFIType: {
    readonly i32: number;
    readonly u32: number;
    readonly ptr: number;
  };
  export const suffix: string;
  export function dlopen(
    path: string,
    symbols: Record<string, { args?: number[]; returns?: number }>,
  ): {
    symbols: Record<string, ((...args: Array<number | Buffer>) => number) | undefined>;
  };
  export const read: {
    i32(address: number, byteOffset?: number): number;
  };
}
