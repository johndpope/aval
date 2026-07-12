export interface LicenseReport { readonly schemaVersion: "1.0"; readonly lockfileSha256: string; readonly policySha256: string; readonly packages: readonly Readonly<Record<string, unknown>>[] }
export function validateLicensePolicy<T extends object>(input: T): T;
export function createLicenseReport(lockBytes: Uint8Array, policyBytes: Uint8Array): LicenseReport;
export function reconcileLicenseReport<T extends object>(report: T, lockBytes: Uint8Array, policyBytes: Uint8Array): T;
export function dependencyLicenseRecords(lock: unknown): readonly Readonly<Record<string, unknown>>[];
