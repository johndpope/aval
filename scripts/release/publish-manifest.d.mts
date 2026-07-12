export function createPublishManifest<T extends object>(source: T): Readonly<Record<string, unknown>>;
export function validatePublishManifest<T extends object>(manifest: T): T;
