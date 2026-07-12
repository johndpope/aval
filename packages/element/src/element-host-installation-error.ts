/** Carries cleanup for a host installation call that may have succeeded before throwing. */
export class ElementHostInstallationError extends Error {
  readonly #retryCleanup: () => boolean;

  public constructor(error: unknown, retryCleanup: () => boolean) {
    super(error instanceof Error ? error.message : "element host installation failed");
    this.name = "ElementHostInstallationError";
    this.#retryCleanup = retryCleanup;
  }

  public retryCleanup(): boolean { return this.#retryCleanup(); }
}

export function hostInstallationError(
  error: unknown,
  retryCleanup: () => boolean
): ElementHostInstallationError {
  try { retryCleanup(); } catch { /* the caller retains the retry */ }
  return new ElementHostInstallationError(error, retryCleanup);
}

export function retryHostInstallationCleanup(error: unknown): boolean | null {
  return error instanceof ElementHostInstallationError
    ? error.retryCleanup()
    : null;
}
