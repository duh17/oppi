/**
 * The SF Symbol names a blocks node's `icon` may carry.
 *
 * An allow-list, not a filter: the host resolves the name on the device, so a surface may only
 * name a symbol this list has been checked to draw. It is deliberately symbols that read at
 * caption size and exist on every OS version the app supports, and it grows by adding a row here
 * — never by letting an author name an arbitrary string.
 */
export const EXTENSION_UI_SURFACE_ICON_NAMES = [
  "arrow.clockwise",
  "arrow.down.circle",
  "arrow.triangle.2.circlepath",
  "arrow.up.circle",
  "arrow.up.right",
  "bell",
  "bell.slash",
  "bolt",
  "book",
  "calendar",
  "chart.bar",
  "checkmark",
  "checkmark.circle",
  "checkmark.circle.fill",
  "checkmark.seal",
  "circle",
  "chevron.right",
  "clock",
  "cloud",
  "cloud.fill",
  "doc",
  "doc.text",
  "exclamationmark.circle",
  "exclamationmark.triangle",
  "exclamationmark.triangle.fill",
  "eye",
  "eye.slash",
  "folder",
  "gearshape",
  "globe",
  "hammer",
  "heart",
  "info.circle",
  "link",
  "list.bullet",
  "lock",
  "lock.open",
  "magnifyingglass",
  "minus.circle",
  "network",
  "paperplane",
  "person",
  "person.2",
  "play",
  "plus",
  "plus.circle",
  "questionmark.circle",
  "server.rack",
  "shield",
  "sparkles",
  "sparkles.rectangle.stack",
  "square.and.arrow.up",
  "star",
  "stop",
  "tag",
  "terminal",
  "trash",
  "tray",
  "xmark",
  "xmark.circle",
  "xmark.circle.fill",
] as const;

/**
 * The one `icon` node name that is not an SF Symbol: the host's still working mark, the same mark
 * session rows show for a working agent. Only an `icon` node takes it; a badge, a control, or a
 * pane names a symbol.
 */
export const EXTENSION_UI_SURFACE_WORKING_ICON = "working";

/** What a client that predates the working mark is sent in its place. */
export const EXTENSION_UI_SURFACE_WORKING_ICON_STAND_IN = "arrow.triangle.2.circlepath";

const ICON_NAMES: ReadonlySet<string> = new Set(EXTENSION_UI_SURFACE_ICON_NAMES);

export function isExtensionUISurfaceIconName(value: string): boolean {
  return ICON_NAMES.has(value);
}
