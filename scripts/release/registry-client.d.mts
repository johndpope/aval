export function isDefinitiveRegistryNotFound(value: string): boolean;
export function parseRegistryJson(output: string, label?: string): unknown;
export interface RegistrySpawnResult { readonly status: number | null; readonly stdout?: string; readonly stderr?: string; readonly error?: Error }
export type RegistrySpawn = (command: string, args: readonly string[], options: Readonly<Record<string, unknown>>) => RegistrySpawnResult;
export function readRegistryState(name: string, version: string, options?: Readonly<{ spawn?: RegistrySpawn; registry?: string }>): Readonly<{
  name: string;
  version: string;
  integrity: string | null;
  tags: Readonly<Record<string, string | null>>;
  deprecation: string | null;
}>;
export function readStableRegistryState(name: string, version: string, options?: Readonly<{ spawn?: RegistrySpawn; registry?: string; stabilityAttempts?: number }>): ReturnType<typeof readRegistryState>;
export function runRegistryMutation(
  args: readonly string[],
  options?: Readonly<{ cwd?: string; timeout?: number; spawn?: RegistrySpawn; registry?: string }>
): void;
export function canonicalRegistryUrl(value: string): string;
