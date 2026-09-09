/** Installed bun:ffi surface used by sim-pool-lock. Not a substitute for @types/node. */
declare module "bun:ffi" {
  export const FFIType: {
    readonly i32: number;
  };
  export const suffix: string;
  export function dlopen(
    path: string,
    symbols: Record<string, { args?: number[]; returns?: number }>,
  ): {
    symbols: Record<string, ((...args: number[]) => number) | undefined>;
  };
}
