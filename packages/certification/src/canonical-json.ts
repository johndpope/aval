import { CertificationValidationError } from "./status.js";

export type CanonicalValue =
  | null
  | boolean
  | number
  | string
  | readonly CanonicalValue[]
  | { readonly [key: string]: CanonicalValue };

export interface CanonicalJsonLimits {
  readonly maxDepth: number;
  readonly maxNodes: number;
  readonly maxStringLength: number;
  readonly maxBytes: number;
}

export const DEFAULT_CANONICAL_LIMITS: CanonicalJsonLimits = Object.freeze({
  maxDepth: 64,
  maxNodes: 200_000,
  maxStringLength: 1_048_576,
  maxBytes: 16 * 1024 * 1024
});

const FORBIDDEN_KEYS = new Set(["__proto__", "prototype", "constructor"]);

export function canonicalJson(
  input: unknown,
  limits: CanonicalJsonLimits = DEFAULT_CANONICAL_LIMITS
): string {
  let nodes = 0;
  const ancestors = new Set<object>();

  function visit(value: unknown, path: string, depth: number): string {
    nodes += 1;
    if (nodes > limits.maxNodes) fail(path, "node limit exceeded");
    if (depth > limits.maxDepth) fail(path, "depth limit exceeded");

    if (value === null) return "null";
    if (typeof value === "boolean") return value ? "true" : "false";
    if (typeof value === "number") {
      if (!Number.isFinite(value)) fail(path, "number must be finite");
      if (Number.isInteger(value) && !Number.isSafeInteger(value)) {
        fail(path, "integer must be safe");
      }
      if (Object.is(value, -0)) return "0";
      return JSON.stringify(value);
    }
    if (typeof value === "string") {
      if (value.length > limits.maxStringLength) fail(path, "string limit exceeded");
      rejectUnpairedSurrogates(value, path);
      return JSON.stringify(value);
    }
    if (typeof value !== "object") fail(path, "unsupported JSON value");
    if (ancestors.has(value)) fail(path, "cyclic value");
    ancestors.add(value);
    try {
      if (Array.isArray(value)) {
        return `[${value.map((item, index) => visit(item, `${path}[${index}]`, depth + 1)).join(",")}]`;
      }
      const prototype = Object.getPrototypeOf(value);
      if (prototype !== Object.prototype && prototype !== null) {
        fail(path, "object must have a plain prototype");
      }
      const record = value as Record<string, unknown>;
      const keys = Object.keys(record).sort(compareUnicodeScalars);
      const fields = keys.map((key) => {
        if (FORBIDDEN_KEYS.has(key)) fail(`${path}.${key}`, "forbidden object key");
        rejectUnpairedSurrogates(key, `${path}.<key>`);
        return `${JSON.stringify(key)}:${visit(record[key], `${path}.${key}`, depth + 1)}`;
      });
      return `{${fields.join(",")}}`;
    } finally {
      ancestors.delete(value);
    }
  }

  const output = `${visit(input, "$", 1)}\n`;
  if (new TextEncoder().encode(output).byteLength > limits.maxBytes) {
    fail("$", "encoded byte limit exceeded");
  }
  return output;
}

export function canonicalJsonBytes(
  input: unknown,
  limits: CanonicalJsonLimits = DEFAULT_CANONICAL_LIMITS
): Uint8Array {
  return new TextEncoder().encode(canonicalJson(input, limits));
}

function compareUnicodeScalars(left: string, right: string): number {
  const leftPoints = [...left];
  const rightPoints = [...right];
  const length = Math.min(leftPoints.length, rightPoints.length);
  for (let index = 0; index < length; index += 1) {
    const leftPoint = leftPoints[index]?.codePointAt(0) ?? 0;
    const rightPoint = rightPoints[index]?.codePointAt(0) ?? 0;
    if (leftPoint !== rightPoint) return leftPoint - rightPoint;
  }
  return leftPoints.length - rightPoints.length;
}

function rejectUnpairedSurrogates(value: string, path: string): void {
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index);
    if (code >= 0xd800 && code <= 0xdbff) {
      const next = value.charCodeAt(index + 1);
      if (!(next >= 0xdc00 && next <= 0xdfff)) fail(path, "unpaired high surrogate");
      index += 1;
    } else if (code >= 0xdc00 && code <= 0xdfff) {
      fail(path, "unpaired low surrogate");
    }
  }
}

function fail(path: string, message: string): never {
  throw new CertificationValidationError(path, message);
}
