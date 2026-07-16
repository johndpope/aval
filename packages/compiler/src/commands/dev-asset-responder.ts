import { createHash } from "node:crypto";
import type { ServerResponse } from "node:http";

import { readBoundedFile, type BoundedReadAdmission } from "./dev-file-reader.js";
import { writeError } from "./dev-http-response.js";
import type { DevServerBuild } from "./dev-server-model.js";

export interface PublishedDevFile {
  readonly bytes: number;
  readonly sha256: string;
}

/** Serve one file only when it still belongs to the published bundle generation. */
export async function servePublishedBundleFile(input: Readonly<{
  response: ServerResponse;
  method: string;
  rangeHeader: string | undefined;
  ifRangeHeader: string | string[] | undefined;
  filePath: string;
  file: Readonly<PublishedDevFile>;
  maximumBytes: number;
  contentType: string;
  published: Readonly<DevServerBuild>;
  current: () => Readonly<DevServerBuild> | null;
  admission: BoundedReadAdmission;
}>): Promise<void> {
  const read = await readBoundedFile(
    input.filePath,
    input.maximumBytes,
    input.admission
  );
  if (read.status === "busy") {
    return writeError(input.response, input.method, 503, "server-busy");
  }
  if (read.status !== "ok") {
    return writeError(input.response, input.method, 503, "build-changing");
  }
  if (
    input.current() !== input.published ||
    read.bytes.byteLength !== input.file.bytes ||
    createHash("sha256").update(read.bytes).digest("hex") !== input.file.sha256
  ) {
    return writeError(input.response, input.method, 503, "build-changing");
  }
  serveFileRange({
    response: input.response,
    method: input.method,
    rangeHeader: input.rangeHeader,
    ifRangeHeader: input.ifRangeHeader,
    bytes: read.bytes,
    sha256: input.file.sha256,
    contentType: input.contentType
  });
}

export function serveFileRange(input: Readonly<{
  response: ServerResponse;
  method: string;
  rangeHeader: string | undefined;
  ifRangeHeader: string | string[] | undefined;
  bytes: Buffer;
  sha256: string;
  contentType: string;
}>): void {
  const etag = `"aval-${input.sha256}"`;
  const honorRange = input.rangeHeader !== undefined && (
    input.ifRangeHeader === undefined || input.ifRangeHeader === etag
  );
  const range = !honorRange
    ? null
    : parseFileRange(input.rangeHeader!, input.bytes.byteLength);
  input.response.setHeader("Accept-Ranges", "bytes");
  input.response.setHeader("Cache-Control", "no-store");
  input.response.setHeader("ETag", etag);
  if (honorRange && range === null) {
    input.response.setHeader(
      "Content-Range",
      `bytes */${String(input.bytes.byteLength)}`
    );
    writeError(input.response, input.method, 416, "invalid-range");
    return;
  }
  const start = range?.start ?? 0;
  const end = range?.end ?? input.bytes.byteLength - 1;
  const body = input.bytes.subarray(start, end + 1);
  input.response.statusCode = range === null ? 200 : 206;
  input.response.setHeader("Content-Type", input.contentType);
  input.response.setHeader("Content-Encoding", "identity");
  input.response.setHeader("Content-Length", body.byteLength);
  if (range !== null) {
    input.response.setHeader(
      "Content-Range",
      `bytes ${String(start)}-${String(end)}/${String(input.bytes.byteLength)}`
    );
  }
  if (input.method === "HEAD") input.response.end();
  else input.response.end(body);
}

export function parseFileRange(
  value: string,
  length: number
): Readonly<{ start: number; end: number }> | null {
  const match = /^bytes=([0-9]+)-([0-9]+)$/u.exec(value);
  if (match === null) return null;
  const start = Number(match[1]);
  const end = Number(match[2]);
  return Number.isSafeInteger(start) && Number.isSafeInteger(end) &&
    start >= 0 && end >= start && end < length
    ? Object.freeze({ start, end })
    : null;
}
