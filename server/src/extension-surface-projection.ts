import type {
  ExtensionUISurface,
  ExtensionUISurfaceNode,
  ExtensionUISurfaceTone,
} from "./types.js";

/**
 * The v1 projection of a blocks tree: the blocks an older client can already draw.
 *
 * Nothing here validates; `extension-surface.ts` has already accepted the tree. A control v1 has
 * no shape for — a button, a toggle, a menu — is collected by title instead of dropped, so a
 * projected surface never loses a verb the surface offered.
 */

/** The line a v1 panel shows under its title: the pill's own words when the surface has one. */
export function v1PillSubtitle(surface: ExtensionUISurface): string | undefined {
  if (!surface.pill) return surface.header.subtitle;
  const parts = surface.pill.content.children.map((child) => {
    switch (child.type) {
      case "text":
      case "badge":
        return child.text;
      case "icon":
        return undefined;
      case "progress":
        return child.label;
      default:
        return undefined;
    }
  });
  const line = parts.filter((part): part is string => Boolean(part)).join(" · ");
  return line.length > 0 ? line : surface.header.subtitle;
}

export function v1TextBlock(id: string | undefined, line: string): unknown {
  return { type: "text", ...(id === undefined ? {} : { id }), spans: [{ text: line }] };
}

function v1SpanRole(tone: ExtensionUISurfaceTone | undefined): string | undefined {
  return tone === undefined || tone === "neutral" ? undefined : tone;
}

/** The primitives a row reads as a single line: everything else keeps its own block. */
const V1_INLINE_NODE_TYPES = new Set(["text", "badge", "icon"]);

function v1InlineText(node: ExtensionUISurfaceNode): string | undefined {
  switch (node.type) {
    case "text":
    case "badge":
      return node.text;
    case "icon":
      return node.name;
    default:
      return undefined;
  }
}

/**
 * One node as v1 blocks, collecting the controls v1 has no shape for. Layout becomes a group or,
 * when every child is an inline fact, one line; controls are named in the caller's text.
 *
 * `actionTitle` names an action id for that text: the caller holds the surface's action table, and
 * a row action carries no title of its own.
 */
export function projectNodeToV1(
  node: ExtensionUISurfaceNode,
  controls: string[],
  actionTitle: (id: string) => string = (id) => id,
): unknown[] {
  const id = node.id;
  switch (node.type) {
    case "row":
    case "stack": {
      const inline = node.children.every((child) => V1_INLINE_NODE_TYPES.has(child.type));
      if (inline) {
        // An inline fact that offers a tap is still a verb v1 cannot draw, one line or not.
        for (const child of node.children) {
          if ("action" in child && child.action) controls.push(actionTitle(child.action.id));
        }
        const line = node.children
          .map((child) => v1InlineText(child))
          .filter((part): part is string => Boolean(part))
          .join(" · ");
        return line.length > 0 ? [v1TextBlock(id, line)] : [];
      }
      const projected = node.children.flatMap((child) =>
        projectNodeToV1(child, controls, actionTitle),
      );
      // A layout of nothing but controls draws nothing: an empty group is not content either.
      if (projected.length === 0) return [];
      return [
        {
          type: "section",
          ...(id === undefined ? {} : { id }),
          blocks: projected,
        },
      ];
    }
    case "group":
      // v1 has no disclosure: a group is its heading and its contents, always unfolded.
      return [
        {
          type: "section",
          ...(id === undefined ? {} : { id }),
          blocks: [
            v1TextBlock(undefined, node.title),
            ...node.children.flatMap((child) => projectNodeToV1(child, controls, actionTitle)),
          ],
        },
      ];
    case "text":
      return [
        {
          type: "text",
          ...(id === undefined ? {} : { id }),
          spans: [
            {
              text: node.text,
              ...(node.style === "mono"
                ? { role: "code" }
                : v1SpanRole(node.tone) === undefined
                  ? {}
                  : { role: v1SpanRole(node.tone) }),
            },
          ],
        },
      ];
    case "markdown":
      return [{ type: "markdown", ...(id === undefined ? {} : { id }), markdown: node.markdown }];
    case "badge":
      return [
        {
          type: "text",
          ...(id === undefined ? {} : { id }),
          spans: [
            {
              text: node.text,
              ...(v1SpanRole(node.tone) === undefined ? {} : { role: v1SpanRole(node.tone) }),
            },
          ],
        },
      ];
    case "icon":
      // v1 has no icon: its name is the only honest text it can show.
      return [v1TextBlock(id, node.name)];
    case "progress":
      return [
        {
          type: "progress",
          ...(id === undefined ? {} : { id }),
          ...(node.label === undefined ? {} : { label: node.label }),
          ...(node.value === undefined ? { indeterminate: true } : { value: node.value }),
        },
      ];
    case "keyValue":
      return [
        {
          type: "text",
          ...(id === undefined ? {} : { id }),
          spans: [{ text: node.pairs.map((pair) => `${pair.key}: ${pair.value}`).join("\n") }],
        },
      ];
    case "table":
      // A row action is a verb v1 cannot draw either: its row's actions are named once each.
      for (const row of node.rows) {
        for (const action of row.actions ?? []) controls.push(actionTitle(action.id));
      }
      return [
        {
          type: "table",
          ...(id === undefined ? {} : { id }),
          columns: node.columns,
          rows: node.rows.map((row) => row.cells),
          ...(node.truncated === undefined ? {} : { truncated: node.truncated }),
        },
      ];
    case "chart":
      return [
        {
          type: "chart",
          ...(id === undefined ? {} : { id }),
          kind: node.kind,
          ...(node.title === undefined ? {} : { title: node.title }),
          labels: node.labels,
          series: node.series,
          ...(node.truncated === undefined ? {} : { truncated: node.truncated }),
        },
      ];
    case "code":
      return [
        {
          type: "code",
          ...(id === undefined ? {} : { id }),
          ...(node.language === undefined ? {} : { language: node.language }),
          text: node.text,
        },
      ];
    case "divider":
      return [{ type: "divider", ...(id === undefined ? {} : { id }) }];
    case "spacer":
      return [
        {
          type: "spacer",
          ...(id === undefined ? {} : { id }),
          ...(node.size === undefined ? {} : { size: node.size }),
        },
      ];
    case "button":
      controls.push(node.title);
      return [];
    case "toggle":
      controls.push(`${node.title} (${node.value ? "on" : "off"})`);
      return [];
    case "menu":
      controls.push(
        [node.title, node.items.map((item) => item.title).join(" / ")]
          .filter((part): part is string => Boolean(part))
          .join(": "),
      );
      return [];
  }
}
