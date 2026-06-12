/** Host extension names suppressed by Oppi before native pi loading. */
export const MANAGED_EXTENSION_NAMES = [] as const;

const MANAGED_EXTENSION_NAME_SET = new Set<string>(MANAGED_EXTENSION_NAMES);

export function isManagedExtensionName(name: string): boolean {
  return MANAGED_EXTENSION_NAME_SET.has(name);
}
