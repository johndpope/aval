export interface MeasurementInterruption {
  readonly kind: "hidden" | "blur" | "pagehide" | "freeze";
  readonly atMicroseconds: number;
}

/** Retains every mid-run foreground interruption instead of filtering it. */
export class ForegroundMeasurementGuard {
  readonly #enabled: boolean;
  readonly #interruptions: MeasurementInterruption[] = [];
  readonly #onVisibility = (): void => {
    if (document.visibilityState !== "visible") this.#record("hidden");
  };
  readonly #onBlur = (): void => this.#record("blur");
  readonly #onPageHide = (): void => this.#record("pagehide");
  readonly #onFreeze = (): void => this.#record("freeze");
  #stopped = false;

  public constructor(enabled: boolean) {
    this.#enabled = enabled;
    if (!enabled) return;
    document.addEventListener("visibilitychange", this.#onVisibility);
    window.addEventListener("blur", this.#onBlur);
    window.addEventListener("pagehide", this.#onPageHide);
    document.addEventListener("freeze", this.#onFreeze);
  }

  public get interrupted(): boolean { return this.#interruptions.length > 0; }

  public snapshot(): readonly Readonly<MeasurementInterruption>[] {
    return Object.freeze(this.#interruptions.map((entry) => Object.freeze({ ...entry })));
  }

  public assertActive(): void {
    if (!this.#enabled) return;
    if (this.interrupted) throw new Error(`named measurement was interrupted: ${this.#interruptions[0]!.kind}`);
    if (document.visibilityState !== "visible" || !document.hasFocus()) throw new Error("named measurement lost foreground focus");
  }

  public stop(): void {
    if (this.#stopped) return;
    this.#stopped = true;
    if (!this.#enabled) return;
    document.removeEventListener("visibilitychange", this.#onVisibility);
    window.removeEventListener("blur", this.#onBlur);
    window.removeEventListener("pagehide", this.#onPageHide);
    document.removeEventListener("freeze", this.#onFreeze);
  }

  #record(kind: MeasurementInterruption["kind"]): void {
    if (this.#stopped || this.#interruptions.some((entry) => entry.kind === kind)) return;
    const atMicroseconds = Math.floor(performance.timeOrigin * 1_000 + performance.now() * 1_000);
    this.#interruptions.push(Object.freeze({ kind, atMicroseconds }));
  }
}
