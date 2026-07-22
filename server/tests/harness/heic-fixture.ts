function box(type: string, payload: Buffer): Buffer {
  const header = Buffer.alloc(8);
  header.writeUInt32BE(header.length + payload.length, 0);
  header.write(type, 4, 4, "ascii");
  return Buffer.concat([header, payload]);
}

function fullBox(type: string, version: number, payload: Buffer): Buffer {
  const versionAndFlags = Buffer.alloc(4);
  versionAndFlags.writeUInt8(version, 0);
  return box(type, Buffer.concat([versionAndFlags, payload]));
}

function hevcConfiguration(): Buffer {
  const header = Buffer.alloc(23);
  header.writeUInt8(1, 0); // configurationVersion
  header.writeUInt8(1, 1); // Main profile
  header.writeUInt8(120, 12); // general_level_idc
  header.writeUInt8(0xfc | 3, 21); // four-byte NAL lengths
  header.writeUInt8(3, 22); // VPS, SPS, PPS arrays

  const arrays = [32, 33, 34].map((nalType) => {
    // Plausible HEVC NAL header followed by bounded RBSP bytes. This fixture
    // proves only the server's structural HEIF checks, not decoder validity.
    const payload = Buffer.from([nalType << 1, 0x01, 0x80, 0x00]);
    const entry = Buffer.alloc(5);
    entry.writeUInt8(0x80 | nalType, 0);
    entry.writeUInt16BE(1, 1);
    entry.writeUInt16BE(payload.length, 3);
    return Buffer.concat([entry, payload]);
  });
  return box("hvcC", Buffer.concat([header, ...arrays]));
}

function makeMeta(
  itemOffset: number,
  itemLength: number,
  dimensions: { width: number; height: number },
): Buffer {
  const handler = fullBox(
    "hdlr",
    0,
    Buffer.concat([
      Buffer.alloc(4),
      Buffer.from("pict", "ascii"),
      Buffer.alloc(12),
      Buffer.from("PictureHandler\0", "ascii"),
    ]),
  );

  const primaryItem = Buffer.alloc(2);
  primaryItem.writeUInt16BE(1);
  const pitm = fullBox("pitm", 0, primaryItem);

  const infePayload = Buffer.alloc(13);
  infePayload.writeUInt16BE(1, 0);
  infePayload.writeUInt16BE(0, 2);
  infePayload.write("hvc1", 4, 4, "ascii");
  infePayload.write("icon\0", 8, 5, "ascii");
  const infe = fullBox("infe", 2, infePayload);
  const itemInfoPayload = Buffer.alloc(2);
  itemInfoPayload.writeUInt16BE(1);
  const iinf = fullBox("iinf", 0, Buffer.concat([itemInfoPayload, infe]));

  const ilocPayload = Buffer.alloc(18);
  ilocPayload.writeUInt8(0x44, 0); // 32-bit extent offset and length
  ilocPayload.writeUInt8(0, 1); // no base offset or extent index
  ilocPayload.writeUInt16BE(1, 2); // item count
  ilocPayload.writeUInt16BE(1, 4); // item ID
  ilocPayload.writeUInt16BE(0, 6); // data reference index
  ilocPayload.writeUInt16BE(1, 8); // extent count
  ilocPayload.writeUInt32BE(itemOffset, 10);
  ilocPayload.writeUInt32BE(itemLength, 14);
  const iloc = fullBox("iloc", 0, ilocPayload);

  const ispePayload = Buffer.alloc(8);
  ispePayload.writeUInt32BE(dimensions.width, 0);
  ispePayload.writeUInt32BE(dimensions.height, 4);
  const ispe = fullBox("ispe", 0, ispePayload);
  const ipco = box("ipco", Buffer.concat([ispe, hevcConfiguration()]));

  const ipmaPayload = Buffer.alloc(10);
  ipmaPayload.writeUInt32BE(1, 0); // entry count
  ipmaPayload.writeUInt16BE(1, 4); // item ID
  ipmaPayload.writeUInt8(2, 6); // association count
  ipmaPayload.writeUInt8(0x81, 7); // essential ispe, property index 1
  ipmaPayload.writeUInt8(0x82, 8); // essential hvcC, property index 2
  const ipma = fullBox("ipma", 0, ipmaPayload.subarray(0, 9));
  const iprp = box("iprp", Buffer.concat([ipco, ipma]));

  return fullBox("meta", 0, Buffer.concat([handler, pitm, iinf, iloc, iprp]));
}

/**
 * Synthetic HEVC HEIF used to exercise the dependency-free server parser.
 * It is deliberately not an Apple adaptive image glyph or proof that the
 * payload is decoder-valid. Real `NSAdaptiveImageGlyph.imageContent` samples
 * remain required before the picker can be considered product-complete.
 */
export function structuralHeifFixture(
  payload: Buffer = Buffer.from([0, 0, 0, 3, 0x26, 0x01, 0x80]),
  dimensions = { width: 64, height: 64 },
): Buffer {
  const ftyp = heicFileTypeBox();
  const placeholderMeta = makeMeta(0, payload.length, dimensions);
  const itemOffset = ftyp.length + placeholderMeta.length + 8;
  const meta = makeMeta(itemOffset, payload.length, dimensions);
  return Buffer.concat([ftyp, meta, box("mdat", payload)]);
}

/**
 * Structural grid-primary HEIF used to prove the server does not trust tile
 * dimensions as the grid output bound. Like structuralHeifFixture, this is not
 * intended to be decoder-valid.
 */
export function structuralGridHeifFixture(options: {
  gridPayload: Buffer;
  tilePayload?: Buffer;
  dimgTargetCount?: number;
}): Buffer {
  const tilePayload = options.tilePayload ?? Buffer.from([0, 0, 0, 3, 0x26, 0x01, 0x80]);
  const targetCount = options.dimgTargetCount ?? 1;
  const ftyp = heicFileTypeBox();
  const placeholderMeta = makeGridMeta(
    0,
    options.gridPayload.length,
    0,
    tilePayload.length,
    targetCount,
  );
  const gridOffset = ftyp.length + placeholderMeta.length + 8;
  const tileOffset = gridOffset + options.gridPayload.length;
  const meta = makeGridMeta(
    gridOffset,
    options.gridPayload.length,
    tileOffset,
    tilePayload.length,
    targetCount,
  );
  return Buffer.concat([ftyp, meta, box("mdat", Buffer.concat([options.gridPayload, tilePayload]))]);
}

function heicFileTypeBox(): Buffer {
  return box(
    "ftyp",
    Buffer.concat([
      Buffer.from("heic", "ascii"),
      Buffer.alloc(4),
      Buffer.from("mif1heic", "ascii"),
    ]),
  );
}

function makeGridMeta(
  gridOffset: number,
  gridLength: number,
  tileOffset: number,
  tileLength: number,
  dimgTargetCount: number,
): Buffer {
  const handler = fullBox(
    "hdlr",
    0,
    Buffer.concat([
      Buffer.alloc(4),
      Buffer.from("pict", "ascii"),
      Buffer.alloc(12),
      Buffer.from("PictureHandler\0", "ascii"),
    ]),
  );

  const primaryItem = Buffer.alloc(2);
  primaryItem.writeUInt16BE(1);
  const pitm = fullBox("pitm", 0, primaryItem);

  const makeItemInfo = (itemId: number, itemType: string, name: string): Buffer => {
    const nameBytes = Buffer.from(`${name}\0`, "ascii");
    const payload = Buffer.alloc(8 + nameBytes.length);
    payload.writeUInt16BE(itemId, 0);
    payload.writeUInt16BE(0, 2);
    payload.write(itemType, 4, 4, "ascii");
    nameBytes.copy(payload, 8);
    return fullBox("infe", 2, payload);
  };
  const itemInfoPayload = Buffer.alloc(2);
  itemInfoPayload.writeUInt16BE(2);
  const iinf = fullBox(
    "iinf",
    0,
    Buffer.concat([
      itemInfoPayload,
      makeItemInfo(1, "grid", "grid"),
      makeItemInfo(2, "hvc1", "tile"),
    ]),
  );

  const ilocPayload = Buffer.alloc(32);
  ilocPayload.writeUInt8(0x44, 0);
  ilocPayload.writeUInt8(0, 1);
  ilocPayload.writeUInt16BE(2, 2);
  const writeLocation = (offset: number, itemId: number, itemOffset: number, length: number): void => {
    ilocPayload.writeUInt16BE(itemId, offset);
    ilocPayload.writeUInt16BE(0, offset + 2);
    ilocPayload.writeUInt16BE(1, offset + 4);
    ilocPayload.writeUInt32BE(itemOffset, offset + 6);
    ilocPayload.writeUInt32BE(length, offset + 10);
  };
  writeLocation(4, 1, gridOffset, gridLength);
  writeLocation(18, 2, tileOffset, tileLength);
  const iloc = fullBox("iloc", 0, ilocPayload);

  const dimgPayload = Buffer.alloc(4 + dimgTargetCount * 2);
  dimgPayload.writeUInt16BE(1, 0);
  dimgPayload.writeUInt16BE(dimgTargetCount, 2);
  for (let index = 0; index < dimgTargetCount; index += 1) {
    dimgPayload.writeUInt16BE(2, 4 + index * 2);
  }
  const iref = fullBox("iref", 0, box("dimg", dimgPayload));

  const ispePayload = Buffer.alloc(8);
  ispePayload.writeUInt32BE(64, 0);
  ispePayload.writeUInt32BE(64, 4);
  const ipco = box(
    "ipco",
    Buffer.concat([fullBox("ispe", 0, ispePayload), hevcConfiguration()]),
  );
  const ipmaPayload = Buffer.alloc(9);
  ipmaPayload.writeUInt32BE(1, 0);
  ipmaPayload.writeUInt16BE(2, 4);
  ipmaPayload.writeUInt8(2, 6);
  ipmaPayload.writeUInt8(0x81, 7);
  ipmaPayload.writeUInt8(0x82, 8);
  const iprp = box("iprp", Buffer.concat([ipco, fullBox("ipma", 0, ipmaPayload)]));

  return fullBox("meta", 0, Buffer.concat([handler, pitm, iinf, iloc, iref, iprp]));
}

export function replaceBoxType(bytes: Buffer, from: string, to: string): Buffer {
  const copy = Buffer.from(bytes);
  const offset = copy.indexOf(Buffer.from(from, "ascii"));
  if (offset < 0) throw new Error(`box ${from} not found`);
  copy.write(to, offset, 4, "ascii");
  return copy;
}

export function genericMif1NearMiss(): Buffer {
  const bytes = structuralHeifFixture();
  bytes.write("mif1", 8, 4, "ascii");
  const compatibleHeic = bytes.indexOf(Buffer.from("heic", "ascii"), 16);
  if (compatibleHeic >= 0) bytes.write("mif1", compatibleHeic, 4, "ascii");
  return bytes;
}

export function corruptHevcConfigurationNalHeader(bytes: Buffer): Buffer {
  const copy = Buffer.from(bytes);
  const typeOffset = copy.indexOf(Buffer.from("hvcC", "ascii"));
  if (typeOffset < 0) throw new Error("hvcC box not found");
  const firstNalHeader = typeOffset + 4 + 23 + 5;
  copy[firstNalHeader] = 0;
  return copy;
}
