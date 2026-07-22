import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, beforeEach, describe, expect, it } from "vitest";

import {
  ICON_ASSET_MAX_BYTES,
  IconAssetStore,
  IconAssetStoreError,
  sniffHeicIconContainer,
} from "../src/storage/icon-asset-store.js";
import {
  corruptHevcConfigurationNalHeader,
  genericMif1NearMiss,
  replaceBoxType,
  structuralGridHeifFixture,
  structuralHeifFixture,
} from "./harness/heic-fixture.js";

function iconHeifBytes(suffix = "sample"): Buffer {
  const content = Buffer.from(suffix);
  const payload = Buffer.from([0, 0, 0, content.length + 3, 0x26, 0x01, 0x80, ...content]);
  return structuralHeifFixture(payload);
}

let dataDir: string;
let store: IconAssetStore;

beforeEach(() => {
  dataDir = mkdtempSync(join(tmpdir(), "oppi-icon-assets-"));
  store = new IconAssetStore(dataDir);
});

afterEach(() => {
  rmSync(dataDir, { recursive: true, force: true });
});

describe("bounded HEVC HEIF container validation", () => {
  it("accepts a bounded structural HEVC HEIF item graph without claiming adaptive semantics", () => {
    expect(sniffHeicIconContainer(iconHeifBytes())).toMatchObject({
      contentType: "image/heic",
      majorBrand: "heic",
    });
  });

  it.each([
    [Buffer.from("not an image"), "unsupported"],
    [genericMif1NearMiss(), "unsupported"],
    [replaceBoxType(structuralHeifFixture(), "hvcC", "free"), "unsupported"],
    [replaceBoxType(structuralHeifFixture(), "iinf", "free"), "unsupported"],
    [replaceBoxType(structuralHeifFixture(), "ipma", "free"), "unsupported"],
    [corruptHevcConfigurationNalHeader(structuralHeifFixture()), "corrupt"],
  ])("rejects non-HEVC and structural near-misses %#", (bytes, code) => {
    try {
      sniffHeicIconContainer(bytes);
      throw new Error("expected validation failure");
    } catch (error) {
      expect(error).toBeInstanceOf(IconAssetStoreError);
      expect((error as IconAssetStoreError).code).toBe(code);
    }
  });

  it("rejects an item extent outside the declared media payload", () => {
    const bytes = structuralHeifFixture();
    const ilocTypeOffset = bytes.indexOf(Buffer.from("iloc", "ascii"));
    bytes.writeUInt32BE(bytes.length + 100, ilocTypeOffset + 18);

    expect(() => sniffHeicIconContainer(bytes)).toThrow("extent");
  });

  it.each([
    [{ width: 4_097, height: 64 }, "width"],
    [{ width: 64, height: 4_097 }, "height"],
    [{ width: 4_096, height: 4_096 }, "pixel"],
  ])("rejects oversized image dimensions %#", (dimensions, message) => {
    expect(() => sniffHeicIconContainer(structuralHeifFixture(undefined, dimensions))).toThrow(
      message,
    );
  });

  it("bounds item, representation, extent, and codec-configuration counts", () => {
    const itemCount = structuralHeifFixture();
    const iinfTypeOffset = itemCount.indexOf(Buffer.from("iinf", "ascii"));
    itemCount.writeUInt16BE(65, iinfTypeOffset + 8);
    expect(() => sniffHeicIconContainer(itemCount)).toThrow("item count");

    const representationCount = structuralHeifFixture();
    const ipmaTypeOffset = representationCount.indexOf(Buffer.from("ipma", "ascii"));
    representationCount.writeUInt32BE(9, ipmaTypeOffset + 8);
    expect(() => sniffHeicIconContainer(representationCount)).toThrow("representation count");

    const extentCount = structuralHeifFixture();
    const ilocTypeOffset = extentCount.indexOf(Buffer.from("iloc", "ascii"));
    extentCount.writeUInt16BE(17, ilocTypeOffset + 16);
    expect(() => sniffHeicIconContainer(extentCount)).toThrow("extent count");

    const configurationCount = structuralHeifFixture();
    const configurationTypeOffset = configurationCount.indexOf(Buffer.from("hvcC", "ascii"));
    configurationCount.writeUInt8(17, configurationTypeOffset + 26);
    expect(() => sniffHeicIconContainer(configurationCount)).toThrow("array count");
  });

  it("rejects grid primaries instead of trusting oversized or malformed grid output", () => {
    const oversizedGrid = Buffer.alloc(12);
    oversizedGrid.writeUInt8(0, 0); // version
    oversizedGrid.writeUInt8(1, 1); // 32-bit output dimensions
    oversizedGrid.writeUInt8(0, 2); // one row
    oversizedGrid.writeUInt8(0, 3); // one column
    oversizedGrid.writeUInt32BE(4_097, 4);
    oversizedGrid.writeUInt32BE(64, 8);

    for (const gridPayload of [oversizedGrid, Buffer.from([0, 1, 0])]) {
      expect(() =>
        sniffHeicIconContainer(structuralGridHeifFixture({ gridPayload })),
      ).toThrow("grid");
    }
  });

  it("rejects grid dimg fanout before allocating or validating tile representations", () => {
    const boundedGrid = Buffer.alloc(8);
    boundedGrid.writeUInt16BE(64, 4);
    boundedGrid.writeUInt16BE(64, 6);

    expect(() =>
      sniffHeicIconContainer(
        structuralGridHeifFixture({ gridPayload: boundedGrid, dimgTargetCount: 1_024 }),
      ),
    ).toThrow("grid");
  });

  it("rejects a fabricated media bitstream with an invalid length-prefixed NAL", () => {
    const bytes = structuralHeifFixture(Buffer.from([0, 0, 1, 0, 0x26, 0x01]));
    expect(() => sniffHeicIconContainer(bytes)).toThrow("media payload");
  });
});

describe("IconAssetStore", () => {
  it("deduplicates identical bytes under a stable opaque ID", () => {
    const first = store.put(iconHeifBytes(), "image/heic", 100);
    const second = store.put(iconHeifBytes(), "image/heif", 200);

    expect(first.assetId).toMatch(/^ia_[A-Za-z0-9_-]{43}$/);
    expect(second.assetId).toBe(first.assetId);
    expect(second.createdAt).toBe(first.createdAt);
    expect(second.lastUploadedAt).toBe(200);
    expect(store.read(first.assetId).bytes).toEqual(iconHeifBytes());
  });

  it("rejects unsupported declared media types and oversized bodies deterministically", () => {
    expect(() => store.put(iconHeifBytes(), "image/png")).toThrow("media type");
    expect(() => store.put(Buffer.alloc(ICON_ASSET_MAX_BYTES + 1), "image/heic")).toThrow(
      "2 MiB",
    );
  });

  it("rejects traversal IDs and reports missing and corrupt assets", () => {
    expect(() => store.read("../../etc/passwd")).toThrow("asset ID");
    expect(() => store.read(`ia_${"z".repeat(43)}`)).toThrow("not found");

    const record = store.put(iconHeifBytes(), "image/heic");
    const blobPath = join(dataDir, "icon-assets", "blobs", `${record.assetId}.heic`);
    writeFileSync(blobPath, iconHeifBytes("tampered"));
    expect(() => store.read(record.assetId)).toThrow("corrupt");
  });

  it("collects only requested assets that have no durable reference", () => {
    const old = 1_000;
    const retained = store.put(iconHeifBytes("retained"), "image/heic", old);
    const removed = store.put(iconHeifBytes("removed"), "image/heic", old);

    const result = store.collectUnreferenced(
      new Set([retained.assetId]),
      new Set([retained.assetId, removed.assetId]),
      { now: old + 24 * 60 * 60 * 1000 + 1 },
    );

    expect(result.removedAssetIds).toEqual([removed.assetId]);
    expect(store.has(retained.assetId)).toBe(true);
    expect(store.has(removed.assetId)).toBe(false);
    expect(
      existsSync(join(dataDir, "icon-assets", "blobs", `${removed.assetId}.heic`)),
    ).toBe(false);
  });

  it("refreshes the pending-upload lease when identical bytes are uploaded near expiry", () => {
    const uploadedAt = 10_000;
    const nearExpiry = uploadedAt + 24 * 60 * 60 * 1000 - 1;
    const record = store.put(iconHeifBytes("lease"), "image/heic", uploadedAt);

    const refreshed = store.put(iconHeifBytes("lease"), "image/heic", nearExpiry);
    const earlyCleanup = store.collectUnreferenced(new Set(), new Set([record.assetId]), {
      now: nearExpiry + 2,
    });

    expect(refreshed.createdAt).toBe(record.createdAt);
    expect(refreshed.lastUploadedAt).toBe(nearExpiry);
    expect(earlyCleanup.removedAssetIds).toEqual([]);
    expect(store.has(record.assetId)).toBe(true);

    const expiredCleanup = store.collectUnreferenced(new Set(), new Set([record.assetId]), {
      now: nearExpiry + 24 * 60 * 60 * 1000 + 1,
    });
    expect(expiredCleanup.removedAssetIds).toEqual([record.assetId]);
  });

  it("repairs a blob-only commit after an injected metadata failure", () => {
    let faultCount = 0;
    const faulting = new IconAssetStore(dataDir, {
      faultInjector(phase) {
        if (phase === "before_metadata_commit" && faultCount++ === 0) {
          throw new Error("injected metadata failure");
        }
      },
    });
    const bytes = iconHeifBytes("recoverable");

    expect(() => faulting.put(bytes, "image/heic", 100)).toThrow("injected metadata failure");
    const blobs = readdirSync(join(dataDir, "icon-assets", "blobs")).filter((name) =>
      name.endsWith(".heic"),
    );
    expect(blobs).toHaveLength(1);

    const repaired = new IconAssetStore(dataDir).put(bytes, "image/heic", 200);
    expect(new IconAssetStore(dataDir).read(repaired.assetId).bytes).toEqual(bytes);
    expect(readdirSync(join(dataDir, "icon-assets", "metadata"))).toContain(
      `${repaired.assetId}.json`,
    );
    expect(
      readdirSync(join(dataDir, "icon-assets", "blobs")).some((name) => name.endsWith(".tmp")),
    ).toBe(false);
  });

  it("repairs a metadata-only record idempotently without changing its identity", () => {
    const bytes = iconHeifBytes("metadata-only");
    const original = store.put(bytes, "image/heic", 100);
    rmSync(join(dataDir, "icon-assets", "blobs", `${original.assetId}.heic`));

    const repaired = new IconAssetStore(dataDir).put(bytes, "image/heic", 200);

    expect(repaired).toMatchObject({
      assetId: original.assetId,
      createdAt: original.createdAt,
      lastUploadedAt: 200,
    });
    expect(store.read(original.assetId).bytes).toEqual(bytes);
  });

  it("keeps a concurrent writer's final blob and returns one valid record", () => {
    const bytes = iconHeifBytes("concurrent");
    let competingRecord: ReturnType<IconAssetStore["put"]> | undefined;
    let injected = false;
    const firstWriter = new IconAssetStore(dataDir, {
      faultInjector(phase) {
        if (phase === "after_blob_commit" && !injected) {
          injected = true;
          competingRecord = new IconAssetStore(dataDir).put(bytes, "image/heic", 150);
        }
      },
    });

    const firstRecord = firstWriter.put(bytes, "image/heic", 100);
    expect(competingRecord?.assetId).toBe(firstRecord.assetId);
    expect(firstWriter.read(firstRecord.assetId).bytes).toEqual(bytes);
    expect(firstWriter.listRecords()).toHaveLength(1);
  });

  it("enforces a bounded storage quota without evicting existing records", () => {
    const firstBytes = iconHeifBytes("quota-one");
    const secondBytes = iconHeifBytes("quota-two");
    const quotaStore = new IconAssetStore(dataDir, {
      maxStorageBytes: firstBytes.length + secondBytes.length - 1,
    });
    const first = quotaStore.put(firstBytes, "image/heic");

    expect(() => quotaStore.put(secondBytes, "image/heic")).toThrow("quota");
    expect(quotaStore.has(first.assetId)).toBe(true);
  });

  it("persists metadata without embedding bytes", () => {
    const record = store.put(iconHeifBytes(), "image/heic");
    const metadata = readFileSync(
      join(dataDir, "icon-assets", "metadata", `${record.assetId}.json`),
      "utf8",
    );
    expect(metadata).toContain(record.sha256);
    expect(metadata).not.toContain(iconHeifBytes().toString("base64"));
  });
});
