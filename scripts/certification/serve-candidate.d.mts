import type { Server } from "node:http";

export class CandidateAssetNotFoundError extends Error {}
export interface CandidateAssetStore {
  readonly root: string;
  readonly manifestBytes: Buffer;
  readonly manifestDigest: string;
  readonly allowlist: ReadonlyMap<string, Readonly<Record<string, unknown>>>;
}
export function createCandidateAssetStore(input: Readonly<{
  root: string;
  manifestBytes: Uint8Array;
  manifestDigest: string;
  artifacts: readonly Readonly<{ path: string; sha256: string; byteLength: number; mediaType?: string }>[];
}>): CandidateAssetStore;
export function readCandidateAsset(store: CandidateAssetStore, requestPath: string): Promise<Readonly<{
  path: string;
  bytes: Buffer;
  sha256: string;
  mediaType: string;
}>>;
export function startCandidateServer(store: CandidateAssetStore, options?: Readonly<{ port?: number; host?: "127.0.0.1" }>): Server;
