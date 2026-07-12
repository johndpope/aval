const FNV_OFFSET = 0x811c9dc5;
const FNV_PRIME = 0x01000193;

/** Isolates proof transport state without exposing or truncating the query text. */
export function deriveM8ProofSession(search: string): string {
  if (search === "") return "m8-page-default";
  let hash = FNV_OFFSET;
  for (let index = 0; index < search.length; index += 1) {
    hash ^= search.charCodeAt(index);
    hash = Math.imul(hash, FNV_PRIME) >>> 0;
  }
  return `m8-page-${hash.toString(16).padStart(8, "0")}`;
}
