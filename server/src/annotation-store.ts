import { readFile, writeFile, mkdir } from "node:fs/promises";
import { dirname, join } from "node:path";
import { randomUUID } from "node:crypto";

import type {
  AnnotationResolution,
  AnnotationSeverity,
  CreateAnnotationRequest,
  DiffAnnotation,
  UpdateAnnotationRequest,
} from "./types.js";

const ANNOTATIONS_DIR = ".oppi";
const ANNOTATIONS_FILE = "annotations.json";

interface AnnotationFileContents {
  version: 1;
  annotations: DiffAnnotation[];
}

function annotationFilePath(workspaceRoot: string): string {
  return join(workspaceRoot, ANNOTATIONS_DIR, ANNOTATIONS_FILE);
}

async function readAnnotations(workspaceRoot: string): Promise<DiffAnnotation[]> {
  try {
    const raw = await readFile(annotationFilePath(workspaceRoot), "utf8");
    const parsed = JSON.parse(raw) as AnnotationFileContents;
    if (parsed.version !== 1 || !Array.isArray(parsed.annotations)) {
      return [];
    }
    return parsed.annotations;
  } catch {
    return [];
  }
}

async function writeAnnotations(
  workspaceRoot: string,
  annotations: DiffAnnotation[],
): Promise<void> {
  const filePath = annotationFilePath(workspaceRoot);
  await mkdir(dirname(filePath), { recursive: true });
  const contents: AnnotationFileContents = { version: 1, annotations };
  await writeFile(filePath, JSON.stringify(contents, null, 2), "utf8");
}

const VALID_SIDES = new Set(["old", "new", "file"]);
const VALID_AUTHORS = new Set(["human", "agent"]);
const VALID_SEVERITIES = new Set(["info", "warn", "error"]);
const VALID_RESOLUTIONS = new Set(["pending", "accepted", "rejected"]);

export class AnnotationStoreError extends Error {
  constructor(
    public readonly status: number,
    message: string,
  ) {
    super(message);
    this.name = "AnnotationStoreError";
  }
}

export async function listAnnotations(
  workspaceId: string,
  workspaceRoot: string,
  filterPath?: string,
  filterSessionId?: string,
): Promise<DiffAnnotation[]> {
  let annotations = await readAnnotations(workspaceRoot);

  if (filterPath) {
    const normalized = filterPath.trim();
    annotations = annotations.filter((a) => a.path === normalized);
  }

  if (filterSessionId) {
    annotations = annotations.filter((a) => a.sessionId === filterSessionId);
  }

  return annotations;
}

export async function createAnnotation(
  workspaceId: string,
  workspaceRoot: string,
  request: CreateAnnotationRequest,
): Promise<DiffAnnotation> {
  const path = request.path?.trim();
  if (!path) {
    throw new AnnotationStoreError(400, "path is required");
  }

  if (!request.body?.trim()) {
    throw new AnnotationStoreError(400, "body is required");
  }

  if (!VALID_SIDES.has(request.side)) {
    throw new AnnotationStoreError(400, `side must be one of: old, new, file`);
  }

  if (!VALID_AUTHORS.has(request.author)) {
    throw new AnnotationStoreError(400, `author must be one of: human, agent`);
  }

  if (
    request.severity !== null &&
    request.severity !== undefined &&
    !VALID_SEVERITIES.has(request.severity)
  ) {
    throw new AnnotationStoreError(400, `severity must be one of: info, warn, error`);
  }

  if (request.side !== "file" && request.startLine === null) {
    throw new AnnotationStoreError(400, "startLine is required for line-level annotations");
  }

  const now = Date.now();
  const annotation: DiffAnnotation = {
    id: randomUUID(),
    workspaceId,
    path,
    side: request.side,
    startLine: request.startLine ?? null,
    endLine: request.endLine ?? null,
    body: request.body.trim(),
    author: request.author,
    sessionId: request.sessionId ?? null,
    severity: (request.severity as AnnotationSeverity | undefined) ?? null,
    resolution: "pending",
    attachments: request.attachments,
    createdAt: now,
    updatedAt: now,
  };

  const annotations = await readAnnotations(workspaceRoot);
  annotations.push(annotation);
  await writeAnnotations(workspaceRoot, annotations);

  return annotation;
}

export async function updateAnnotation(
  workspaceRoot: string,
  annotationId: string,
  request: UpdateAnnotationRequest,
): Promise<DiffAnnotation> {
  const annotations = await readAnnotations(workspaceRoot);
  const index = annotations.findIndex((a) => a.id === annotationId);

  if (index < 0) {
    throw new AnnotationStoreError(404, "Annotation not found");
  }

  const existing = annotations[index];

  if (
    request.resolution !== null &&
    request.resolution !== undefined &&
    !VALID_RESOLUTIONS.has(request.resolution)
  ) {
    throw new AnnotationStoreError(400, `resolution must be one of: pending, accepted, rejected`);
  }

  if (
    request.severity !== undefined &&
    request.severity !== null &&
    !VALID_SEVERITIES.has(request.severity)
  ) {
    throw new AnnotationStoreError(400, `severity must be one of: info, warn, error`);
  }

  const updated: DiffAnnotation = {
    ...existing,
    body: request.body?.trim() ?? existing.body,
    resolution: (request.resolution as AnnotationResolution | undefined) ?? existing.resolution,
    severity:
      request.severity !== undefined
        ? (request.severity as AnnotationSeverity | null)
        : existing.severity,
    updatedAt: Date.now(),
  };

  annotations[index] = updated;
  await writeAnnotations(workspaceRoot, annotations);

  return updated;
}

export async function deleteAnnotation(workspaceRoot: string, annotationId: string): Promise<void> {
  const annotations = await readAnnotations(workspaceRoot);
  const index = annotations.findIndex((a) => a.id === annotationId);

  if (index < 0) {
    throw new AnnotationStoreError(404, "Annotation not found");
  }

  annotations.splice(index, 1);
  await writeAnnotations(workspaceRoot, annotations);
}
