import { randomUUID } from "node:crypto";
import {
  closeSync,
  existsSync,
  fchmodSync,
  fsyncSync,
  lstatSync,
  mkdirSync,
  openSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";
import {
  DICTATION_CONTEXT_MAX_PHRASES,
  DICTATION_CONTEXT_MAX_PHRASE_BYTES,
} from "../dictation-types.js";

export class DictionaryError extends Error {
  constructor(
    readonly status: number,
    message: string,
  ) {
    super(message);
  }
}

type List = { revision: number; phrases: string[] };
type RecordV1 = { version: 1; global: List; workspaces: Record<string, List> };
const empty = (): List => ({ revision: 0, phrases: [] });
const maxSaved = DICTATION_CONTEXT_MAX_PHRASES;
type SkippedPhrase = { phrase: string; reason: "cap" | "duplicate" | "phrase-bytes" };
type AddResult = List & { added: number; skipped: SkippedPhrase[] };

function phraseText(value: unknown): string {
  if (
    typeof value !== "string" ||
    value.trim() !== value ||
    !value ||
    [...value].some((character) => {
      const point = character.codePointAt(0) ?? 0;
      return point <= 0x1f || (point >= 0x7f && point <= 0x9f);
    })
  ) {
    throw new DictionaryError(400, "Invalid dictionary phrase (empty, whitespace or controls)");
  }
  return value;
}

function validPhrase(value: unknown): string {
  const text = phraseText(value);
  if (Buffer.byteLength(text, "utf8") > DICTATION_CONTEXT_MAX_PHRASE_BYTES)
    throw new DictionaryError(400, "Dictionary phrase exceeds 256 UTF-8 bytes");
  return text;
}

function validList(value: unknown): value is List {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const list = value as Partial<List>;
  if (
    !Number.isSafeInteger(list.revision) ||
    (list.revision ?? -1) < 0 ||
    !Array.isArray(list.phrases) ||
    list.phrases.length > maxSaved
  )
    return false;
  try {
    const phrases = list.phrases.map(validPhrase);
    return new Set(phrases).size === phrases.length;
  } catch {
    return false;
  }
}

export class DictationDictionaryStore {
  private readonly path: string;
  private readonly directory: string;

  constructor(dataDir: string) {
    this.directory = join(dataDir, "settings");
    this.path = join(this.directory, "dictation-dictionary.json");
  }

  get(workspaceId: string | null): List {
    const record = this.read();
    const list = workspaceId === null ? record.global : (record.workspaces[workspaceId] ?? empty());
    return { revision: list.revision, phrases: [...list.phrases] };
  }

  add(workspaceId: string | null, phrase: unknown): List {
    return this.addMany(workspaceId, [validPhrase(phrase)]);
  }

  addMany(workspaceId: string | null, phrases: unknown): AddResult {
    if (!Array.isArray(phrases) || !phrases.length)
      throw new DictionaryError(400, "Expected non-empty phrases array");
    // Validate the entire batch before changing persistent state. Size overflow is reported per item.
    const entries: string[] = phrases.map(phraseText);
    const skipped: SkippedPhrase[] = [];
    let added = 0;
    const list = this.change(workspaceId, (current) => {
      const next = [...current.phrases];
      const seen = new Set(next);
      for (const phrase of entries) {
        let reason: SkippedPhrase["reason"] | undefined;
        if (Buffer.byteLength(phrase, "utf8") > DICTATION_CONTEXT_MAX_PHRASE_BYTES)
          reason = "phrase-bytes";
        else if (seen.has(phrase)) reason = "duplicate";
        else if (next.length >= maxSaved) reason = "cap";
        if (reason) skipped.push({ phrase, reason });
        else {
          next.push(phrase);
          seen.add(phrase);
          added++;
        }
      }
      return next;
    });
    return { ...list, added, skipped };
  }

  remove(workspaceId: string | null, phrase: unknown): List {
    const text = validPhrase(phrase);
    return this.change(workspaceId, (list) => list.phrases.filter((entry) => entry !== text));
  }

  replace(workspaceId: string | null, revision: unknown, phrases: unknown): List {
    if (!Array.isArray(phrases) || phrases.length > maxSaved) {
      throw new DictionaryError(400, "Dictionary allows at most 100 saved phrases per scope");
    }
    const entries = phrases.map(validPhrase);
    if (new Set(entries).size !== entries.length)
      throw new DictionaryError(400, "Duplicate dictionary phrase");
    return this.change(workspaceId, (list) => {
      if (revision !== list.revision)
        throw new DictionaryError(409, "Dictionary changed; reload before saving");
      return entries;
    });
  }

  forget(workspaceId: string): List {
    return this.change(workspaceId, () => []);
  }

  private change(workspaceId: string | null, update: (list: List) => string[]): List {
    const record = this.read();
    const current =
      workspaceId === null ? record.global : (record.workspaces[workspaceId] ?? empty());
    const phrases = update(current);
    if (phrases.length > maxSaved)
      throw new DictionaryError(400, "Dictionary allows at most 100 saved phrases per scope");
    if (
      phrases.length === current.phrases.length &&
      phrases.every((p, i) => p === current.phrases[i])
    ) {
      return { revision: current.revision, phrases: [...phrases] };
    }
    const next = { revision: current.revision + 1, phrases };
    if (workspaceId === null) record.global = next;
    else record.workspaces[workspaceId] = next;
    this.persist(record);
    return { revision: next.revision, phrases: [...next.phrases] };
  }

  private read(): RecordV1 {
    if (!existsSync(this.path))
      return {
        version: 1,
        global: empty(),
        workspaces: Object.create(null) as Record<string, List>,
      };
    try {
      if (!lstatSync(this.path).isFile() || lstatSync(this.path).isSymbolicLink()) throw Error();
      const value: unknown = JSON.parse(readFileSync(this.path, "utf8"));
      if (!value || typeof value !== "object" || Array.isArray(value)) throw Error();
      const record = value as RecordV1;
      if (
        record.version !== 1 ||
        !validList(record.global) ||
        !record.workspaces ||
        typeof record.workspaces !== "object" ||
        Array.isArray(record.workspaces) ||
        !Object.values(record.workspaces).every(validList)
      )
        throw Error();
      return record;
    } catch {
      // Never overwrite a damaged file; doing so can resurrect a previously removed entry.
      throw new DictionaryError(503, "Dictionary store unavailable; repair required");
    }
  }

  private persist(record: RecordV1): void {
    let fd: number | undefined;
    let temp: string | undefined;
    try {
      if (existsSync(this.directory)) {
        const stat = lstatSync(this.directory);
        if (!stat.isDirectory() || stat.isSymbolicLink()) throw Error();
      } else mkdirSync(this.directory, { recursive: true, mode: 0o700 });
      temp = join(this.directory, `.dictation-dictionary.${randomUUID()}.tmp`);
      fd = openSync(temp, "wx", 0o600);
      fchmodSync(fd, 0o600);
      writeFileSync(fd, JSON.stringify(record), "utf8");
      fsyncSync(fd);
      closeSync(fd);
      fd = undefined;
      renameSync(temp, this.path);
      temp = undefined;
      try {
        const dirFd = openSync(this.directory, "r");
        try {
          fsyncSync(dirFd);
        } finally {
          closeSync(dirFd);
        }
      } catch {
        /* File was fsynced and renamed atomically. */
      }
    } catch {
      throw new DictionaryError(503, "Dictionary store unavailable; write failed");
    } finally {
      if (fd !== undefined) closeSync(fd);
      if (temp) rmSync(temp, { force: true });
    }
  }
}
