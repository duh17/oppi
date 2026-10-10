/**
 * The few Workers runtime types this adapter uses. Declared here instead of
 * `@cloudflare/workers-types`, whose globals conflict with the DOM and Node types the core
 * and Node adapter compile against.
 */

interface DurableObjectStorage {
  get<T>(key: string): Promise<T | undefined>;
  put<T>(key: string, value: T): Promise<void>;
  deleteAll(): Promise<void>;
  setAlarm(scheduledTime: number): Promise<void>;
}

interface DurableObjectState {
  readonly storage: DurableObjectStorage;
}

interface DurableObjectId {
  toString(): string;
}

type DurableObjectStub<T> = {
  [K in keyof T]: T[K] extends (...args: infer A) => infer R
    ? (...args: A) => R extends Promise<unknown> ? R : Promise<R>
    : never;
};

interface DurableObjectNamespace<T> {
  idFromName(name: string): DurableObjectId;
  get(id: DurableObjectId): DurableObjectStub<T>;
}

declare module "cloudflare:workers" {
  export abstract class DurableObject<Env = unknown> {
    protected readonly ctx: DurableObjectState;
    protected readonly env: Env;
    constructor(ctx: DurableObjectState, env: Env);
  }
}
