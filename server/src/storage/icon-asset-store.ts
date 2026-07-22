import { createHash, randomUUID } from "node:crypto";
import {
  closeSync,
  existsSync,
  fsyncSync,
  linkSync,
  mkdirSync,
  openSync,
  readFileSync,
  readdirSync,
  renameSync,
  rmSync,
  statSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { dirname, join } from "node:path";

import { ICON_ASSET_ID_PATTERN } from "../icon-choice.js";

export const ICON_ASSET_MAX_BYTES = 2 * 1024 * 1024;
export const ICON_ASSET_ORPHAN_GRACE_MS = 24 * 60 * 60 * 1000;
export const ICON_ASSET_STORAGE_QUOTA_BYTES = 256 * 1024 * 1024;
const ICON_ASSET_MAX_DIMENSION = 4_096;
const ICON_ASSET_MAX_PIXELS = 8_388_608;
const HEIF_MAX_ITEM_COUNT = 64;
const HEIF_MAX_REPRESENTATION_COUNT = 8;
const HEIF_MAX_EXTENTS_PER_ITEM = 16;
const HEVC_MAX_CONFIGURATION_BYTES = 64 * 1024;
const HEVC_MAX_CONFIGURATION_ARRAYS = 16;
const HEVC_MAX_NALS = 64;
const ACCEPTED_MEDIA_TYPES = new Set(["image/heic", "image/heif"]);
const HEVC_IMAGE_BRANDS = new Set(["heic", "heix", "hevc", "hevx", "heim", "heis", "hevm", "hevs"]);
const HEVC_ITEM_TYPES = new Set(["hvc1", "hev1"]);

type CommitFaultPhase = "after_blob_commit" | "before_metadata_commit";

export interface IconAssetStoreOptions {
  maxStorageBytes?: number;
  /** Deterministic fault seam for crash/retry behavior tests. */
  faultInjector?: (phase: CommitFaultPhase) => void;
}

export type IconAssetErrorCode =
  | "oversized"
  | "unsupported"
  | "corrupt"
  | "invalid_id"
  | "missing"
  | "quota";

export class IconAssetStoreError extends Error {
  constructor(
    readonly code: IconAssetErrorCode,
    message: string,
    readonly status: number,
  ) {
    super(message);
    this.name = "IconAssetStoreError";
  }
}

export interface IconAssetRecord {
  assetId: string;
  sha256: string;
  sizeBytes: number;
  contentType: "image/heic";
  createdAt: number;
  /** Durable picker-draft lease, refreshed by every deduplicated upload. */
  lastUploadedAt: number;
}

export interface IconAssetContent {
  record: IconAssetRecord;
  bytes: Buffer;
}

export interface HeicIconContainerInfo {
  contentType: "image/heic";
  majorBrand: string;
  compatibleBrands: string[];
}

interface IsoBox {
  type: string;
  start: number;
  end: number;
  payloadStart: number;
  payloadEnd: number;
}

interface ItemExtent {
  offset: number;
  length: number;
  constructionMethod: number;
}

export class IconAssetStore {
  private readonly root: string;
  private readonly blobsDir: string;
  private readonly metadataDir: string;
  private readonly maxStorageBytes: number;
  private readonly faultInjector?: (phase: CommitFaultPhase) => void;

  constructor(dataDir: string, options: IconAssetStoreOptions = {}) {
    this.root = join(dataDir, "icon-assets");
    this.blobsDir = join(this.root, "blobs");
    this.metadataDir = join(this.root, "metadata");
    this.maxStorageBytes = options.maxStorageBytes ?? ICON_ASSET_STORAGE_QUOTA_BYTES;
    this.faultInjector = options.faultInjector;
    mkdirSync(this.blobsDir, { recursive: true, mode: 0o700 });
    mkdirSync(this.metadataDir, { recursive: true, mode: 0o700 });
    removeAbandonedTemporaryFiles(this.blobsDir);
    removeAbandonedTemporaryFiles(this.metadataDir);
  }

  put(bytes: Buffer, declaredContentType: string | undefined, now = Date.now()): IconAssetRecord {
    validateDeclaredContentType(declaredContentType);
    sniffHeicIconContainer(bytes);

    const sha256 = createHash("sha256").update(bytes).digest("hex");
    const assetId = `ia_${Buffer.from(sha256, "hex").toString("base64url")}`;
    const blobPath = this.blobPath(assetId);
    const metadataPath = this.metadataPath(assetId);
    const hadBlob = existsSync(blobPath);
    const hadMetadata = existsSync(metadataPath);

    if (hadBlob && hadMetadata) {
      const existing = this.read(assetId).record;
      const refreshed = {
        ...existing,
        lastUploadedAt: Math.max(existing.lastUploadedAt, now),
      };
      if (refreshed.lastUploadedAt !== existing.lastUploadedAt) {
        replaceDurableFile(metadataPath, Buffer.from(`${JSON.stringify(refreshed, null, 2)}\n`));
      }
      return this.read(assetId).record;
    }

    const existingRecord = hadMetadata ? this.readMetadata(metadataPath, assetId) : undefined;
    if (
      existingRecord &&
      (existingRecord.sha256 !== sha256 || existingRecord.sizeBytes !== bytes.length)
    ) {
      throw new IconAssetStoreError("corrupt", "Icon asset metadata conflicts with its ID", 422);
    }
    if (hadBlob) validateBlob(readFileSync(blobPath), sha256, bytes.length);

    if (!hadBlob && !hadMetadata) this.assertWithinQuota(bytes.length);

    if (!hadBlob) {
      createDurableFileIfAbsent(blobPath, bytes);
      validateBlob(readFileSync(blobPath), sha256, bytes.length);
    }
    this.faultInjector?.("after_blob_commit");

    const blobCreatedAt = Math.floor(statSync(blobPath).mtimeMs);
    const record: IconAssetRecord = existingRecord ?? {
      assetId,
      sha256,
      sizeBytes: bytes.length,
      contentType: "image/heic",
      createdAt: Math.min(now, blobCreatedAt),
      lastUploadedAt: now,
    };
    const refreshedRecord = {
      ...record,
      lastUploadedAt: Math.max(record.lastUploadedAt, now),
    };

    this.faultInjector?.("before_metadata_commit");
    const metadata = Buffer.from(`${JSON.stringify(refreshedRecord, null, 2)}\n`);
    if (hadMetadata) replaceDurableFile(metadataPath, metadata);
    else createDurableFileIfAbsent(metadataPath, metadata);

    return this.read(assetId).record;
  }

  has(assetId: string): boolean {
    try {
      return this.read(assetId).record.assetId === assetId;
    } catch {
      return false;
    }
  }

  read(assetId: string): IconAssetContent {
    assertAssetId(assetId);
    const content = this.readIfPresent(assetId);
    if (!content) {
      throw new IconAssetStoreError("missing", "Icon asset not found", 404);
    }
    return content;
  }

  listRecords(): IconAssetRecord[] {
    if (!existsSync(this.metadataDir)) return [];
    const records: IconAssetRecord[] = [];
    for (const name of readdirSync(this.metadataDir).sort()) {
      if (!name.endsWith(".json")) continue;
      const assetId = name.slice(0, -5);
      try {
        records.push(this.read(assetId).record);
      } catch {
        // Corrupt records remain observable through GET and are reconciled only
        // after the reference-owning stores have supplied a complete live set.
      }
    }
    return records;
  }

  collectUnreferenced(
    referencedAssetIds: ReadonlySet<string>,
    candidateAssetIds?: ReadonlySet<string>,
    options: { now?: number; graceMs?: number } = {},
  ): { removedAssetIds: string[] } {
    const now = options.now ?? Date.now();
    const graceMs = candidateAssetIds
      ? (options.graceMs ?? 0)
      : (options.graceMs ?? ICON_ASSET_ORPHAN_GRACE_MS);
    const candidates = candidateAssetIds ?? this.listCandidateAssetIds();
    const removedAssetIds: string[] = [];

    for (const assetId of [...candidates].sort()) {
      assertAssetId(assetId);
      if (referencedAssetIds.has(assetId)) continue;
      const timestamps = this.assetTimestamps(assetId);
      if (now - timestamps.createdAt < graceMs) continue;
      if (now - timestamps.lastUploadedAt < ICON_ASSET_ORPHAN_GRACE_MS) continue;

      const hadBlob = existsSync(this.blobPath(assetId));
      const hadMetadata = existsSync(this.metadataPath(assetId));
      rmSync(this.metadataPath(assetId), { force: true });
      rmSync(this.blobPath(assetId), { force: true });
      if (hadMetadata) syncDirectory(this.metadataDir);
      if (hadBlob) syncDirectory(this.blobsDir);
      if (hadBlob || hadMetadata) removedAssetIds.push(assetId);
    }
    return { removedAssetIds };
  }

  storageBytes(): number {
    if (!existsSync(this.blobsDir)) return 0;
    let total = 0;
    for (const name of readdirSync(this.blobsDir)) {
      if (!name.endsWith(".heic")) continue;
      try {
        total += statSync(join(this.blobsDir, name)).size;
      } catch {
        // A concurrently removed file contributes no retained bytes.
      }
    }
    return total;
  }

  private assertWithinQuota(additionalBytes: number): void {
    if (this.storageBytes() + additionalBytes <= this.maxStorageBytes) return;
    throw new IconAssetStoreError("quota", "Icon asset storage quota exceeded", 507);
  }

  private listCandidateAssetIds(): Set<string> {
    const ids = new Set<string>();
    for (const name of readdirSync(this.blobsDir)) {
      if (name.endsWith(".heic")) ids.add(name.slice(0, -5));
    }
    for (const name of readdirSync(this.metadataDir)) {
      if (name.endsWith(".json")) ids.add(name.slice(0, -5));
    }
    return new Set([...ids].filter((id) => ICON_ASSET_ID_PATTERN.test(id)));
  }

  private assetTimestamps(assetId: string): { createdAt: number; lastUploadedAt: number } {
    const metadataPath = this.metadataPath(assetId);
    if (existsSync(metadataPath)) {
      try {
        const record = this.readMetadata(metadataPath, assetId);
        return { createdAt: record.createdAt, lastUploadedAt: record.lastUploadedAt };
      } catch {
        const modifiedAt = statSync(metadataPath).mtimeMs;
        return { createdAt: modifiedAt, lastUploadedAt: modifiedAt };
      }
    }
    const blobPath = this.blobPath(assetId);
    const modifiedAt = existsSync(blobPath) ? statSync(blobPath).mtimeMs : Date.now();
    return { createdAt: modifiedAt, lastUploadedAt: modifiedAt };
  }

  private readIfPresent(assetId: string): IconAssetContent | undefined {
    assertAssetId(assetId);
    const metadataPath = this.metadataPath(assetId);
    const blobPath = this.blobPath(assetId);
    if (!existsSync(metadataPath) && !existsSync(blobPath)) return undefined;
    if (!existsSync(metadataPath) || !existsSync(blobPath)) {
      throw new IconAssetStoreError("corrupt", "Icon asset is incomplete", 422);
    }

    const record = this.readMetadata(metadataPath, assetId);
    const bytes = readFileSync(blobPath);
    validateBlob(bytes, record.sha256, record.sizeBytes);
    try {
      sniffHeicIconContainer(bytes);
    } catch {
      throw new IconAssetStoreError("corrupt", "Icon asset container is corrupt", 422);
    }
    return { record, bytes };
  }

  private readMetadata(path: string, assetId: string): IconAssetRecord {
    let rawRecord: unknown;
    try {
      rawRecord = JSON.parse(readFileSync(path, "utf8"));
    } catch {
      throw new IconAssetStoreError("corrupt", "Icon asset metadata is corrupt", 422);
    }
    return validateRecord(rawRecord, assetId);
  }

  private blobPath(assetId: string): string {
    return join(this.blobsDir, `${assetId}.heic`);
  }

  private metadataPath(assetId: string): string {
    return join(this.metadataDir, `${assetId}.json`);
  }
}

/**
 * Dependency-free structural validation for the bounded HEVC HEIF asset that
 * Oppi stores. This does not authenticate Apple adaptive-image semantics or
 * prove full decoder validity. The official authenticated iOS/iPadOS picker is
 * responsible for supplying NSAdaptiveImageGlyph.imageContent; physical glyph
 * samples remain required before that picker flow is product-complete.
 */
export function sniffHeicIconContainer(bytes: Buffer): HeicIconContainerInfo {
  if (bytes.length > ICON_ASSET_MAX_BYTES) {
    throw new IconAssetStoreError("oversized", "Icon asset exceeds the 2 MiB maximum", 413);
  }
  if (bytes.length < 16) unsupported("Unsupported icon asset container");

  const topLevel = parseBoxes(bytes, 0, bytes.length);
  const ftyp = topLevel[0];
  if (!ftyp || ftyp.type !== "ftyp" || ftyp.payloadEnd - ftyp.payloadStart < 8) {
    unsupported("Unsupported icon asset container");
  }

  const majorBrand = ascii(bytes, ftyp.payloadStart, 4);
  const compatibleStart = ftyp.payloadStart + 8;
  if ((ftyp.payloadEnd - compatibleStart) % 4 !== 0) corrupt("Corrupt ISO-BMFF ftyp box");
  const compatibleBrands: string[] = [];
  for (let offset = compatibleStart; offset < ftyp.payloadEnd; offset += 4) {
    compatibleBrands.push(ascii(bytes, offset, 4));
  }
  if (![majorBrand, ...compatibleBrands].some((brand) => HEVC_IMAGE_BRANDS.has(brand))) {
    unsupported("Unsupported icon asset brand; expected an HEVC image brand");
  }

  const meta = topLevel.find((entry) => entry.type === "meta");
  const mediaBoxes = topLevel.filter((entry) => entry.type === "mdat");
  if (!meta || mediaBoxes.length === 0)
    unsupported("HEIC item metadata and media payload required");
  validateHeifItemGraph(bytes, meta, mediaBoxes);

  return { contentType: "image/heic", majorBrand, compatibleBrands };
}

function validateHeifItemGraph(bytes: Buffer, meta: IsoBox, mediaBoxes: IsoBox[]): void {
  if (meta.payloadEnd - meta.payloadStart < 4) corrupt("Corrupt HEIF meta box");
  const children = parseBoxes(bytes, meta.payloadStart + 4, meta.payloadEnd);
  const handler = requiredBox(children, "hdlr");
  if (handler.payloadEnd - handler.payloadStart < 12) corrupt("Corrupt HEIF handler box");
  if (ascii(bytes, handler.payloadStart + 8, 4) !== "pict") {
    unsupported("HEIF metadata is not a picture item graph");
  }

  const primaryItemId = parsePrimaryItem(bytes, requiredBox(children, "pitm"));
  const itemTypes = parseItemTypes(bytes, requiredBox(children, "iinf"));
  const primaryType = itemTypes.get(primaryItemId);
  // Grid-derived images have independent output dimensions and tile fanout.
  // Reject them until those fields, dimg cardinality, aggregate extents, and
  // allocation bounds are all parsed and enforced. Direct hvc1/hev1 primaries
  // retain the existing bounded validation path.
  if (primaryType === "grid") {
    unsupported("Primary HEIF grid items are not supported");
  }
  if (!primaryType || !HEVC_ITEM_TYPES.has(primaryType)) {
    unsupported("Primary HEIF item is not backed by an HEVC image item");
  }

  const locations = parseItemLocations(bytes, requiredBox(children, "iloc"));
  const { properties, associations } = parseItemProperties(bytes, requiredBox(children, "iprp"));
  const codecItemIds = [primaryItemId];

  for (const itemId of codecItemIds) {
    const extents = locations.get(itemId);
    if (!extents || extents.length === 0) unsupported("HEVC image item has no media extent");
    let totalExtentBytes = 0;
    for (const extent of extents) {
      if (extent.constructionMethod !== 0) {
        unsupported("Unsupported HEVC image item construction method");
      }
      totalExtentBytes += extent.length;
      if (totalExtentBytes > ICON_ASSET_MAX_BYTES) {
        unsupported("HEVC image item extent bytes exceed the icon bound");
      }
      const contained = mediaBoxes.some(
        (media) =>
          extent.offset >= media.payloadStart &&
          extent.length > 0 &&
          extent.offset + extent.length <= media.payloadEnd,
      );
      if (!contained) corrupt("HEVC image item extent is outside the media payload");
    }

    const propertyIndexes = associations.get(itemId) ?? new Set<number>();
    const itemProperties = [...propertyIndexes].map((index) => properties[index - 1]);
    const dimensions = itemProperties.find((property) => property?.type === "ispe");
    const codec = itemProperties.find((property) => property?.type === "hvcC");
    if (!dimensions || !codec) {
      unsupported("HEVC image item requires associated ispe and hvcC properties");
    }
    validateDimensions(bytes, dimensions);
    const nalLengthSize = validateHevcConfiguration(bytes, codec);
    validateHevcMediaPayload(bytes, extents, nalLengthSize);
  }
}

function parsePrimaryItem(bytes: Buffer, box: IsoBox): number {
  const version = fullBoxVersion(bytes, box);
  const offset = box.payloadStart + 4;
  if (version === 0) return readUInt(bytes, offset, 2, box.payloadEnd);
  if (version === 1) return readUInt(bytes, offset, 4, box.payloadEnd);
  unsupported("Unsupported pitm version");
}

function parseItemTypes(bytes: Buffer, box: IsoBox): Map<number, string> {
  const version = fullBoxVersion(bytes, box);
  let offset = box.payloadStart + 4;
  const countSize = version === 0 ? 2 : 4;
  const count = readUInt(bytes, offset, countSize, box.payloadEnd);
  if (count < 1 || count > HEIF_MAX_ITEM_COUNT) {
    unsupported(`HEIF item count must be between 1 and ${HEIF_MAX_ITEM_COUNT}`);
  }
  offset += countSize;
  const entries = parseBoxes(bytes, offset, box.payloadEnd);
  if (entries.length !== count) corrupt("Corrupt HEIF item info box");

  const result = new Map<number, string>();
  for (const entry of entries.slice(0, count)) {
    if (entry.type !== "infe") continue;
    const entryVersion = fullBoxVersion(bytes, entry);
    let cursor = entry.payloadStart + 4;
    const itemIdSize = entryVersion === 2 ? 2 : entryVersion === 3 ? 4 : 0;
    if (itemIdSize === 0) continue;
    const itemId = readUInt(bytes, cursor, itemIdSize, entry.payloadEnd);
    cursor += itemIdSize + 2;
    result.set(itemId, asciiChecked(bytes, cursor, 4, entry.payloadEnd));
  }
  if (result.size === 0) unsupported("HEIF item info has no typed items");
  return result;
}

function parseItemLocations(bytes: Buffer, box: IsoBox): Map<number, ItemExtent[]> {
  const version = fullBoxVersion(bytes, box);
  let offset = box.payloadStart + 4;
  const sizesA = readUInt(bytes, offset, 1, box.payloadEnd);
  const sizesB = readUInt(bytes, offset + 1, 1, box.payloadEnd);
  offset += 2;
  const offsetSize = sizesA >> 4;
  const lengthSize = sizesA & 0x0f;
  const baseOffsetSize = sizesB >> 4;
  const indexSize = version === 1 || version === 2 ? sizesB & 0x0f : 0;
  const itemCountSize = version < 2 ? 2 : 4;
  const itemCount = readUInt(bytes, offset, itemCountSize, box.payloadEnd);
  if (itemCount < 1 || itemCount > HEIF_MAX_ITEM_COUNT) {
    unsupported(`HEIF location item count must be between 1 and ${HEIF_MAX_ITEM_COUNT}`);
  }
  offset += itemCountSize;

  const result = new Map<number, ItemExtent[]>();
  for (let itemIndex = 0; itemIndex < itemCount; itemIndex += 1) {
    const itemIdSize = version < 2 ? 2 : 4;
    const itemId = readUInt(bytes, offset, itemIdSize, box.payloadEnd);
    offset += itemIdSize;
    let constructionMethod = 0;
    if (version === 1 || version === 2) {
      constructionMethod = readUInt(bytes, offset, 2, box.payloadEnd) & 0x0f;
      offset += 2;
    }
    offset += 2; // data_reference_index
    const baseOffset = readVariableUInt(bytes, offset, baseOffsetSize, box.payloadEnd);
    offset += baseOffsetSize;
    const extentCount = readUInt(bytes, offset, 2, box.payloadEnd);
    if (extentCount < 1 || extentCount > HEIF_MAX_EXTENTS_PER_ITEM) {
      unsupported(`HEIF extent count must be between 1 and ${HEIF_MAX_EXTENTS_PER_ITEM} per item`);
    }
    offset += 2;
    const extents: ItemExtent[] = [];
    for (let extentIndex = 0; extentIndex < extentCount; extentIndex += 1) {
      offset += indexSize;
      const extentOffset = readVariableUInt(bytes, offset, offsetSize, box.payloadEnd);
      offset += offsetSize;
      const extentLength = readVariableUInt(bytes, offset, lengthSize, box.payloadEnd);
      offset += lengthSize;
      const absoluteOffset = baseOffset + extentOffset;
      if (!Number.isSafeInteger(absoluteOffset)) corrupt("HEIF extent offset exceeds safe range");
      extents.push({
        offset: absoluteOffset,
        length: extentLength,
        constructionMethod,
      });
    }
    result.set(itemId, extents);
  }
  return result;
}

function parseItemProperties(
  bytes: Buffer,
  box: IsoBox,
): { properties: IsoBox[]; associations: Map<number, Set<number>> } {
  const children = parseBoxes(bytes, box.payloadStart, box.payloadEnd);
  const ipco = requiredBox(children, "ipco");
  const ipma = requiredBox(children, "ipma");
  const properties = parseBoxes(bytes, ipco.payloadStart, ipco.payloadEnd);
  if (properties.length < 1 || properties.length > HEIF_MAX_ITEM_COUNT) {
    unsupported(`HEIF property count must be between 1 and ${HEIF_MAX_ITEM_COUNT}`);
  }

  const version = fullBoxVersion(bytes, ipma);
  const flags = bytes.readUIntBE(ipma.payloadStart + 1, 3);
  let offset = ipma.payloadStart + 4;
  const entryCount = readUInt(bytes, offset, 4, ipma.payloadEnd);
  if (entryCount < 1 || entryCount > HEIF_MAX_REPRESENTATION_COUNT) {
    unsupported(`HEIF representation count must be between 1 and ${HEIF_MAX_REPRESENTATION_COUNT}`);
  }
  offset += 4;
  const associations = new Map<number, Set<number>>();
  for (let entry = 0; entry < entryCount; entry += 1) {
    const idSize = version < 1 ? 2 : 4;
    const itemId = readUInt(bytes, offset, idSize, ipma.payloadEnd);
    offset += idSize;
    const associationCount = readUInt(bytes, offset, 1, ipma.payloadEnd);
    offset += 1;
    const indexes = new Set<number>();
    for (let index = 0; index < associationCount; index += 1) {
      const associationSize = flags & 1 ? 2 : 1;
      const raw = readUInt(bytes, offset, associationSize, ipma.payloadEnd);
      offset += associationSize;
      const propertyIndex = associationSize === 2 ? raw & 0x7fff : raw & 0x7f;
      if (propertyIndex > 0 && propertyIndex <= properties.length) indexes.add(propertyIndex);
    }
    associations.set(itemId, indexes);
  }
  return { properties, associations };
}

function validateDimensions(bytes: Buffer, box: IsoBox): void {
  fullBoxVersion(bytes, box);
  const width = readUInt(bytes, box.payloadStart + 4, 4, box.payloadEnd);
  const height = readUInt(bytes, box.payloadStart + 8, 4, box.payloadEnd);
  if (width < 1) corrupt("HEVC image width is invalid");
  if (height < 1) corrupt("HEVC image height is invalid");
  if (width > ICON_ASSET_MAX_DIMENSION) unsupported("HEVC image width exceeds the icon bound");
  if (height > ICON_ASSET_MAX_DIMENSION) unsupported("HEVC image height exceeds the icon bound");
  if (width * height > ICON_ASSET_MAX_PIXELS) {
    unsupported("HEVC image pixel count exceeds the icon bound");
  }
}

function validateHevcConfiguration(bytes: Buffer, box: IsoBox): number {
  const length = box.payloadEnd - box.payloadStart;
  if (length < 23 || length > HEVC_MAX_CONFIGURATION_BYTES || bytes[box.payloadStart] !== 1) {
    corrupt("HEVC decoder configuration is invalid");
  }
  const profileIdc = (bytes[box.payloadStart + 1] ?? 0) & 0x1f;
  const levelIdc = bytes[box.payloadStart + 12] ?? 0;
  const lengthSizeMinusOne = (bytes[box.payloadStart + 21] ?? 0) & 0x03;
  if (profileIdc < 1 || levelIdc < 1 || lengthSizeMinusOne === 2) {
    corrupt("HEVC decoder configuration fields are invalid");
  }

  const arrayCount = bytes[box.payloadStart + 22] ?? 0;
  if (arrayCount < 1 || arrayCount > HEVC_MAX_CONFIGURATION_ARRAYS) {
    corrupt(`HEVC decoder configuration array count exceeds ${HEVC_MAX_CONFIGURATION_ARRAYS}`);
  }
  let offset = box.payloadStart + 23;
  let totalNalCount = 0;
  const nalTypes = new Set<number>();
  for (let arrayIndex = 0; arrayIndex < arrayCount; arrayIndex += 1) {
    const nalType = readUInt(bytes, offset, 1, box.payloadEnd) & 0x3f;
    offset += 1;
    const nalCount = readUInt(bytes, offset, 2, box.payloadEnd);
    offset += 2;
    totalNalCount += nalCount;
    if (nalCount < 1 || totalNalCount > HEVC_MAX_NALS) {
      corrupt("HEVC decoder configuration NAL count is invalid");
    }
    for (let nalIndex = 0; nalIndex < nalCount; nalIndex += 1) {
      const nalLength = readUInt(bytes, offset, 2, box.payloadEnd);
      offset += 2;
      if (nalLength < 2 || offset + nalLength > box.payloadEnd) {
        corrupt("HEVC decoder configuration NAL data is invalid");
      }
      validateHevcNalHeader(bytes.subarray(offset, offset + nalLength), nalType);
      offset += nalLength;
    }
    if (nalTypes.has(nalType)) corrupt("HEVC decoder configuration repeats a NAL array");
    nalTypes.add(nalType);
  }
  if (offset !== box.payloadEnd) corrupt("HEVC decoder configuration has trailing data");
  if (![32, 33, 34].every((type) => nalTypes.has(type))) {
    unsupported("HEVC decoder configuration requires VPS, SPS, and PPS data");
  }
  return lengthSizeMinusOne + 1;
}

function validateHevcNalHeader(nal: Buffer, expectedType?: number): number {
  if (nal.length < 2) corrupt("HEVC NAL data is truncated");
  const type = ((nal[0] ?? 0) >> 1) & 0x3f;
  const temporalIdPlusOne = (nal[1] ?? 0) & 0x07;
  if (temporalIdPlusOne === 0 || (expectedType !== undefined && type !== expectedType)) {
    corrupt("HEVC NAL header is invalid");
  }
  return type;
}

function validateHevcMediaPayload(
  bytes: Buffer,
  extents: ItemExtent[],
  nalLengthSize: number,
): void {
  const payload = Buffer.concat(
    extents.map((extent) => bytes.subarray(extent.offset, extent.offset + extent.length)),
  );
  let offset = 0;
  let nalCount = 0;
  let hasVcl = false;
  while (offset < payload.length) {
    const nalLength = readUInt(payload, offset, nalLengthSize, payload.length);
    offset += nalLengthSize;
    if (nalLength < 2 || offset + nalLength > payload.length) {
      corrupt("HEVC media payload has an invalid length-prefixed NAL");
    }
    const type = validateHevcNalHeader(payload.subarray(offset, offset + nalLength));
    hasVcl ||= type <= 31;
    offset += nalLength;
    nalCount += 1;
    if (nalCount > HEVC_MAX_NALS) corrupt("HEVC media payload has too many NAL units");
  }
  if (offset !== payload.length || !hasVcl) {
    corrupt("HEVC media payload does not contain a bounded VCL NAL unit");
  }
}

function parseBoxes(bytes: Buffer, start: number, end: number): IsoBox[] {
  const boxes: IsoBox[] = [];
  let offset = start;
  while (offset < end) {
    if (end - offset < 8) corrupt("Corrupt ISO-BMFF box header");
    const size32 = bytes.readUInt32BE(offset);
    const type = ascii(bytes, offset + 4, 4);
    let headerSize = 8;
    let size: number;
    if (size32 === 1) {
      if (end - offset < 16) corrupt("Corrupt ISO-BMFF extended box header");
      const extended = bytes.readBigUInt64BE(offset + 8);
      if (extended > BigInt(Number.MAX_SAFE_INTEGER)) corrupt("ISO-BMFF box is too large");
      size = Number(extended);
      headerSize = 16;
    } else if (size32 === 0) {
      size = end - offset;
    } else {
      size = size32;
    }
    if (size < headerSize || offset + size > end) corrupt("Corrupt ISO-BMFF box size");
    boxes.push({
      type,
      start: offset,
      end: offset + size,
      payloadStart: offset + headerSize,
      payloadEnd: offset + size,
    });
    offset += size;
    if (size32 === 0) break;
  }
  return boxes;
}

function requiredBox(boxes: IsoBox[], type: string): IsoBox {
  const box = boxes.find((candidate) => candidate.type === type);
  if (!box) unsupported(`HEIF ${type} box required`);
  return box;
}

function fullBoxVersion(bytes: Buffer, box: IsoBox): number {
  return readUInt(bytes, box.payloadStart, 1, box.payloadEnd);
}

function readUInt(bytes: Buffer, offset: number, size: number, end: number): number {
  if (size < 1 || size > 6 || offset < 0 || offset + size > end) {
    corrupt("Corrupt HEIF integer field");
  }
  return bytes.readUIntBE(offset, size);
}

function readVariableUInt(bytes: Buffer, offset: number, size: number, end: number): number {
  if (size === 0) return 0;
  if (size > 8 || offset < 0 || offset + size > end) {
    corrupt("Corrupt HEIF variable integer field");
  }
  let value = 0n;
  for (let index = 0; index < size; index += 1) {
    value = (value << 8n) | BigInt(bytes[offset + index] ?? 0);
  }
  if (value > BigInt(Number.MAX_SAFE_INTEGER)) corrupt("HEIF integer exceeds safe range");
  return Number(value);
}

function ascii(bytes: Buffer, offset: number, length: number): string {
  return bytes.toString("ascii", offset, offset + length);
}

function asciiChecked(bytes: Buffer, offset: number, length: number, end: number): string {
  if (offset < 0 || offset + length > end) corrupt("Corrupt HEIF string field");
  return ascii(bytes, offset, length);
}

function unsupported(message: string): never {
  throw new IconAssetStoreError("unsupported", message, 415);
}

function corrupt(message: string): never {
  throw new IconAssetStoreError("corrupt", message, 422);
}

function validateDeclaredContentType(contentType: string | undefined): void {
  const normalized = contentType?.split(";", 1)[0]?.trim().toLowerCase();
  if (!normalized || !ACCEPTED_MEDIA_TYPES.has(normalized)) {
    throw new IconAssetStoreError(
      "unsupported",
      "Unsupported icon asset media type; expected image/heic or image/heif",
      415,
    );
  }
}

function assertAssetId(assetId: string): void {
  if (!ICON_ASSET_ID_PATTERN.test(assetId)) {
    throw new IconAssetStoreError("invalid_id", "Invalid icon asset ID", 400);
  }
}

function validateRecord(raw: unknown, expectedAssetId: string): IconAssetRecord {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    throw new IconAssetStoreError("corrupt", "Icon asset metadata is corrupt", 422);
  }
  const value = raw as Record<string, unknown>;
  if (
    value.assetId !== expectedAssetId ||
    typeof value.sha256 !== "string" ||
    !/^[a-f0-9]{64}$/.test(value.sha256) ||
    !Number.isInteger(value.sizeBytes) ||
    (value.sizeBytes as number) < 1 ||
    (value.sizeBytes as number) > ICON_ASSET_MAX_BYTES ||
    value.contentType !== "image/heic" ||
    typeof value.createdAt !== "number" ||
    !Number.isFinite(value.createdAt) ||
    (value.lastUploadedAt !== undefined &&
      (typeof value.lastUploadedAt !== "number" || !Number.isFinite(value.lastUploadedAt)))
  ) {
    throw new IconAssetStoreError("corrupt", "Icon asset metadata is corrupt", 422);
  }
  const createdAt = value.createdAt as number;
  const lastUploadedAt = (value.lastUploadedAt as number | undefined) ?? createdAt;
  if (lastUploadedAt < createdAt) {
    throw new IconAssetStoreError("corrupt", "Icon asset metadata is corrupt", 422);
  }
  return { ...value, createdAt, lastUploadedAt } as IconAssetRecord;
}

function validateBlob(bytes: Buffer, expectedHash: string, expectedSize: number): void {
  if (bytes.length !== expectedSize || bytes.length > ICON_ASSET_MAX_BYTES) {
    throw new IconAssetStoreError("corrupt", "Icon asset is corrupt: blob size mismatch", 422);
  }
  const actualHash = createHash("sha256").update(bytes).digest("hex");
  if (actualHash !== expectedHash) {
    throw new IconAssetStoreError("corrupt", "Icon asset is corrupt: hash mismatch", 422);
  }
}

function createDurableFileIfAbsent(path: string, bytes: Buffer): void {
  const temporaryPath = `${path}.${process.pid}.${randomUUID()}.tmp`;
  writeFileSync(temporaryPath, bytes, { mode: 0o600, flag: "wx", flush: true });
  try {
    try {
      linkSync(temporaryPath, path);
      syncDirectory(dirname(path));
    } catch (error) {
      if (!isAlreadyExistsError(error)) throw error;
    }
  } finally {
    rmSync(temporaryPath, { force: true });
  }
}

function replaceDurableFile(path: string, bytes: Buffer): void {
  const temporaryPath = `${path}.${process.pid}.${randomUUID()}.tmp`;
  writeFileSync(temporaryPath, bytes, { mode: 0o600, flag: "wx", flush: true });
  try {
    renameSync(temporaryPath, path);
    syncDirectory(dirname(path));
  } finally {
    rmSync(temporaryPath, { force: true });
  }
}

function removeAbandonedTemporaryFiles(directory: string): void {
  const cutoff = Date.now() - ICON_ASSET_ORPHAN_GRACE_MS;
  let removed = false;
  for (const name of readdirSync(directory)) {
    if (!name.endsWith(".tmp")) continue;
    const path = join(directory, name);
    if (statSync(path).mtimeMs > cutoff) continue;
    unlinkSync(path);
    removed = true;
  }
  if (removed) syncDirectory(directory);
}

function syncDirectory(directory: string): void {
  const descriptor = openSync(directory, "r");
  try {
    fsyncSync(descriptor);
  } finally {
    closeSync(descriptor);
  }
}

function isAlreadyExistsError(error: unknown): boolean {
  return (
    error instanceof Error && "code" in error && (error as NodeJS.ErrnoException).code === "EEXIST"
  );
}
