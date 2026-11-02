import type { Static } from "@earendil-works/pi-schema";

/**
 * A pi-schema schema as a classic Pi tool's `parameters`, the one typing bridge every classic
 * entry uses (`ask`, `bash`, `background_job`, `subagent`, `notify`, `speak`, sandbox `grep`).
 *
 * Pi validates a tool's arguments as plain JSON Schema at run time (1.5: pi-ai's
 * `validateToolArguments` compiles `parameters` with pi-schema; 1.4: TypeBox's `Compile`, which
 * also takes plain JSON Schema), so pi-schema's output works as is. Only the types lag:
 * `ToolDefinition<TParams extends TSchema>` hands `execute` TypeBox's `Static<TParams>`, which is
 * `unknown` for a pi-schema schema. TypeBox reads the value type of a `TUnsafe` from its `~unsafe`
 * key, so this adds that key at the type level; nothing exists at run time. Use it as a cast:
 * `parameters: Params as ClassicParams<typeof Params>`.
 *
 * Classic schemas stay open (no `additionalProperties: false`), as TypeBox's `Type.Object` was:
 * the Pi terminal and classic sessions share these entries.
 *
 * The Pi packages (`ask`, `background-jobs`, `subagents`) write their schemas out as the JSON
 * pi-schema's builders make, typed with its `Schema<T>`, and import pi-schema for types only. Pi
 * hands an extension only its own modules (pi-coding-agent, pi-ai, pi-tui, pi-agent-core,
 * typebox) and resolves any other package from the extension's path, which through a
 * `~/.pi/agent/extensions` link or copy has no `node_modules`. The server's own classic tools
 * (`notify`, `speak`, `grep`) load in the server process and use the builders.
 */
export type ClassicParams<S> = S & { readonly "~unsafe": Static<S> };
