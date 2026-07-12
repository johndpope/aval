export function validateSpdxDocument<T extends object>(input: T, limits?: Readonly<{ maximumPackages?: number; maximumFiles?: number; maximumRelationships?: number }>): T;
export function reconcileWorkspaceSbom(document: unknown, lockBytes: Uint8Array): void;
export function reconcilePackageSbom(document: unknown, archive: Readonly<Record<string, unknown>>): void;
export function reconcileReleaseSbomSet(input: Readonly<{ documentsByPath: ReadonlyMap<string, unknown>; releaseSet: Readonly<{ packages: readonly Readonly<Record<string, unknown>>[] }>; workspaceLockBytes: Uint8Array }>): void;
export function workspacePackageRecords(lock: unknown): readonly Readonly<{ path: string; name: string; version: string; license: string; integrity: string | null }>[];
