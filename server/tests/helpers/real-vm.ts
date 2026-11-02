/**
 * Why a real Gondolin VM cannot boot on this host, or undefined when it can.
 *
 * A VM needs two things from the host: QEMU, and a guest image. The image comes from the machine's
 * image store (`GONDOLIN_IMAGE_STORE`, pointed at the machine cache by `vitest.setup.ts`); with no
 * image there the SDK pulls one from GitHub on first boot — the builtin image registry, then the
 * release archive — which an offline host cannot do. Name the reason so a real-VM test skips, the
 * way it already skips a host without QEMU, instead of failing inside that fetch.
 */
import { isQemuAvailable } from "../../src/gondolin-manager.js";

/** The SDK default (`DEFAULT_IMAGE_REGISTRY_URL` in gondolin's `images.js`); its env override wins. */
const IMAGE_REGISTRY_URL =
  process.env.GONDOLIN_IMAGE_REGISTRY_URL?.trim() ||
  "https://raw.githubusercontent.com/earendil-works/gondolin/main/builtin-image-registry.json";

export async function realVmSkipReason(): Promise<string | undefined> {
  if (!(await isQemuAvailable())) return "QEMU is not installed (brew install qemu)";
  // Resolves the store, GONDOLIN_GUEST_DIR, and a local gondolin checkout: no network.
  const { getImageStoreDirectory, hasGuestAssets } = await import("@earendil-works/gondolin");
  if (hasGuestAssets()) return undefined;
  // A warm store answers above; a cold one needs this one fetch to ever get an image, so probe it
  // rather than letting the boot fail later with the SDK's own network error.
  if (await imageRegistryReachable()) return undefined;
  return (
    `no Gondolin guest image in ${getImageStoreDirectory()} and no network to fetch one ` +
    `(${IMAGE_REGISTRY_URL})`
  );
}

/** Whether the first fetch of a guest image could succeed: one HEAD, no download. */
async function imageRegistryReachable(): Promise<boolean> {
  try {
    const response = await fetch(IMAGE_REGISTRY_URL, {
      method: "HEAD",
      signal: AbortSignal.timeout(3_000),
    });
    return response.ok;
  } catch {
    return false;
  }
}
