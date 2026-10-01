import type { ToolInputPresentation, ToolOutputPresentation } from "./types.js";
function asRecord(v: unknown): Record<string, unknown> | undefined {
  return typeof v === "object" && v !== null ? (v as Record<string, unknown>) : undefined;
}
export const BUILTIN_INPUT_PRESENTATIONS: Record<string, ToolInputPresentation> = {
  codemode: { fields: { code: { role: "code", language: "javascript" } } },
  bash: { fields: { command: { role: "command", language: "shell" } } },
  read: {
    fields: {
      path: { role: "filePath" },
      offset: { role: "lineOffset" },
      limit: { role: "lineLimit" },
    },
  },
  write: { fields: { path: { role: "filePath" }, content: { role: "fileContent" } } },
  edit: { fields: { path: { role: "filePath" }, edits: { role: "edits" } } },
};

export const BUILTIN_OUTPUT_PRESENTATIONS: Record<string, ToolOutputPresentation> = {
  voice_reply_mode: { kind: "structured", settingEffect: "voiceReplyMode" },
  bash: { kind: "terminal" },
  read: { kind: "fileContent", provenance: "result" },
  write: { kind: "fileContent", provenance: "requested" },
  edit: { kind: "diffOfEdits", provenance: "result" },
  ask: { kind: "interactive" },
};

/** A result can override content semantics, but cannot grant itself a setting effect. */
export function resolveOutputPresentation(
  declaration: unknown,
  details: unknown,
): ToolOutputPresentation | undefined {
  const payload = asRecord(details);
  const effect =
    asRecord(declaration)?.settingEffect === "voiceReplyMode"
      ? ("voiceReplyMode" as const)
      : undefined;
  const fact =
    payload?.outputPresentation !== undefined
      ? (validatedOutputPresentation(payload.outputPresentation) ?? { kind: "structured" as const })
      : typeof payload?.expandedText === "string" && payload.expandedText.trim()
        ? {
            kind:
              payload.presentationFormat === "terminal"
                ? ("terminal" as const)
                : ("structured" as const),
          }
        : validatedOutputPresentation(declaration);
  return fact ? { ...fact, ...(effect ? { settingEffect: effect } : {}) } : undefined;
}

function validatedOutputPresentation(value: unknown): ToolOutputPresentation | undefined {
  const fact = asRecord(value);
  if (
    !fact ||
    !["terminal", "structured", "fileContent", "diffOfEdits", "interactive"].includes(
      String(fact.kind),
    )
  )
    return undefined;
  if (
    fact.provenance !== undefined &&
    fact.provenance !== "requested" &&
    fact.provenance !== "result"
  )
    return undefined;
  return {
    kind: fact.kind as ToolOutputPresentation["kind"],
    ...(fact.provenance ? { provenance: fact.provenance as "requested" | "result" } : {}),
  };
}

export function validatedInputPresentation(
  value: unknown,
  onInvalid: () => void,
): ToolInputPresentation | undefined {
  const fields = asRecord(asRecord(value)?.fields);
  if (
    !fields ||
    Array.isArray(fields) ||
    Object.keys(fields).length > 32 ||
    Object.entries(fields).some(([key, field]) => {
      const hint = asRecord(field);
      return (
        !key ||
        key.length > 100 ||
        !hint ||
        ![
          "code",
          "command",
          "filePath",
          "fileContent",
          "edits",
          "lineOffset",
          "lineLimit",
        ].includes(String(hint.role)) ||
        ((hint.role === "code" || hint.role === "command") && typeof hint.language !== "string") ||
        (hint.language !== undefined &&
          (typeof hint.language !== "string" || !/^[a-zA-Z0-9_+-]{1,40}$/.test(hint.language)))
      );
    })
  ) {
    onInvalid();
    return undefined;
  }
  return {
    fields: Object.fromEntries(
      Object.entries(fields).map(([key, field]) => {
        const hint = asRecord(field);
        return [
          key,
          {
            role: hint?.role as ToolInputPresentation["fields"][string]["role"],
            ...(typeof hint?.language === "string" ? { language: hint.language } : {}),
          },
        ];
      }),
    ),
  };
}
