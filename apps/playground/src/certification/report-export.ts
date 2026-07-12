const MAX_REPORT_BYTES = 16 * 1024 * 1024;
const PRIVATE_FIELD = /(?:authorization|cookie|password|profilepath|serial|token|username)/iu;

export interface CertificationExport {
  readonly bytes: Uint8Array;
  readonly sha256: string;
  readonly canonicalJson: string;
}

export async function createReportExport(report: unknown): Promise<CertificationExport> {
  rejectPrivateFields(report, "$report", new WeakSet());
  const canonicalJson = `${JSON.stringify(sortValue(report))}\n`;
  const bytes = new TextEncoder().encode(canonicalJson);
  if (bytes.byteLength > MAX_REPORT_BYTES) throw new RangeError("certification report exceeds the byte limit");
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  const sha256 = [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
  return Object.freeze({ bytes, sha256, canonicalJson });
}

export function offerReportDownload(report: CertificationExport, name: string): void {
  if (!/^[a-z0-9][a-z0-9._-]{0,127}\.json$/u.test(name)) throw new TypeError("report filename is invalid");
  const url = URL.createObjectURL(new Blob([report.canonicalJson], { type: "application/json" }));
  const anchor = document.createElement("a");
  anchor.download = name;
  anchor.href = url;
  anchor.rel = "noopener";
  anchor.click();
  queueMicrotask(() => URL.revokeObjectURL(url));
}

function sortValue(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortValue);
  if (value !== null && typeof value === "object") {
    return Object.fromEntries(Object.keys(value).sort().map((key) => [key, sortValue((value as Record<string, unknown>)[key])]));
  }
  return value;
}

function rejectPrivateFields(value: unknown, path: string, seen: WeakSet<object>): void {
  if (typeof value === "string") {
    if (/^(?:\/Users\/|\/home\/|[A-Za-z]:[\\/])/u.test(value)) throw new Error(`${path} contains a local path`);
    if (/https?:\/\/[^\s?]+\?[^\s]+/iu.test(value)) throw new Error(`${path} contains an unredacted URL query`);
    return;
  }
  if (value === null || typeof value !== "object") return;
  if (seen.has(value)) throw new TypeError(`${path} contains a cycle`);
  seen.add(value);
  if (Array.isArray(value)) value.forEach((item, index) => rejectPrivateFields(item, `${path}[${String(index)}]`, seen));
  else for (const [key, item] of Object.entries(value)) {
    if (PRIVATE_FIELD.test(key)) throw new Error(`${path}.${key} is a forbidden private field`);
    rejectPrivateFields(item, `${path}.${key}`, seen);
  }
  seen.delete(value);
}
