import type { PublicationLedger, PublicationOperation } from "../../packages/certification/src/publication-ledger.js";

export interface PublicationAuthorizationBinding {
  readonly digest: string;
  readonly releaseDigest: string;
  readonly releaseSet: Readonly<{ releaseSetDigest: string; order: readonly string[] }>;
  readonly policy: Readonly<{ registry: Readonly<{ url: string }> }>;
}
export interface PublicationCertificationAuthority {
  validatePublicationLedger(input: unknown): PublicationLedger;
  canonicalJsonBytes(input: unknown): Uint8Array;
}
export function loadPublicationAuthorization(input: Readonly<Record<string, unknown>>): Promise<Readonly<Record<string, unknown>>>;
export function publicationLedgerEnvelope(authorization: PublicationAuthorizationBinding, input: Readonly<Record<string, unknown>>): PublicationLedger;
export function loadBoundLedger(input: Readonly<{ path: string; expectedDigest: string; authorization: PublicationAuthorizationBinding; certification: PublicationCertificationAuthority }>): Promise<Readonly<{ bytes: Uint8Array; digest: string; ledger: PublicationLedger }>>;
export function writePublicationLedger(input: Readonly<{ output: string; ledger: PublicationLedger; certification: PublicationCertificationAuthority }>): Promise<Readonly<{ bytes: Uint8Array; digest: string }>>;
export function loadRegistryConsumerEvidence(input: Readonly<{ path: string; expectedDigest: string; authorization: PublicationAuthorizationBinding; certification: Pick<PublicationCertificationAuthority, "canonicalJsonBytes"> }>): Promise<Readonly<{ bytes: Uint8Array; digest: string; evidence: Readonly<{ status: "passed" }> }>>;
export function loadMitigationEvidence(input: Readonly<{ path: string; expectedDigest: string }>): Promise<Readonly<{ bytes: Uint8Array; digest: string }>>;
export function terminalLedgerStatus(operations: readonly PublicationOperation[], error: unknown | null): "passed" | "failed" | "inconclusive";
export function validPublicationApproval(value: unknown): boolean;
