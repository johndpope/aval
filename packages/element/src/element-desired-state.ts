import type { ElementConfiguration } from "./element-configuration.js";

export interface ElementDesiredSnapshot {
  readonly revision: number;
  readonly sourceToken: number;
  readonly configuration: Readonly<ElementConfiguration> | null;
  readonly connected: boolean;
  readonly terminal: boolean;
  readonly documentVisible: boolean;
  readonly intersecting: boolean;
  readonly positiveBox: boolean;
  readonly observerSupported: boolean;
  readonly effectivelyVisible: boolean;
  readonly box: Readonly<{ width: number; height: number }>;
  readonly dpr: number;
  readonly hostReducedMotion: boolean | null;
  readonly manualPlaying: boolean;
  readonly playSequence: number;
  readonly stateIntent: Readonly<{ name: string | null; sequence: number }> | null;
  readonly bfcacheRestoreSequence: number;
  readonly realmSequence: number;
  readonly interactionTarget: Element | null;
}

/** Pure desired-state reducer. It performs no DOM or runtime effects. */
export class ElementDesiredState {
  readonly #maximumSequence: number;
  #stateSequence = 0;
  #snapshot: Readonly<ElementDesiredSnapshot> = freezeSnapshot({
    revision: 0,
    sourceToken: 0,
    configuration: null,
    connected: false,
    terminal: false,
    documentVisible: true,
    intersecting: false,
    positiveBox: false,
    observerSupported: true,
    box: Object.freeze({ width: 0, height: 0 }),
    dpr: 1,
    hostReducedMotion: null,
    manualPlaying: true,
    playSequence: 0,
    stateIntent: null,
    bfcacheRestoreSequence: 0,
    realmSequence: 0,
    interactionTarget: null
  });

  public constructor(options: Readonly<{ maximumSequence?: number }> = {}) {
    this.#maximumSequence = options.maximumSequence ?? Number.MAX_SAFE_INTEGER;
    if (!Number.isSafeInteger(this.#maximumSequence) || this.#maximumSequence < 1) {
      throw new RangeError("element desired-state sequence maximum is invalid");
    }
  }

  public snapshot(): Readonly<ElementDesiredSnapshot> { return this.#snapshot; }

  public invalidateSource(): Readonly<ElementDesiredSnapshot> {
    const sourceToken = this.#next(this.#snapshot.sourceToken, "source token");
    const declarativeState = this.#snapshot.configuration?.state ?? null;
    if (declarativeState !== null) {
      this.#stateSequence = this.#next(this.#stateSequence, "state intent sequence");
    }
    return this.#update({
      sourceToken,
      // Imperative commands are generation-scoped. An explicit reflected
      // state survives, while absence lets the new runtime and its startup
      // bindings choose from that manifest's own initial state.
      stateIntent: declarativeState === null
        ? null
        : Object.freeze({
            name: declarativeState,
            sequence: this.#stateSequence
          })
    });
  }

  public configure(configuration: Readonly<ElementConfiguration>): Readonly<ElementDesiredSnapshot> {
    const previous = this.#snapshot.configuration;
    const resetPlayIntent = previous === null || previous.autoplay !== configuration.autoplay;
    return this.#update({
      configuration: freezeConfiguration(configuration),
      ...(resetPlayIntent ? {
        manualPlaying: configuration.autoplay === "visible",
        playSequence: this.#next(this.#snapshot.playSequence, "play sequence")
      } : {})
    });
  }

  public setConnected(connected: boolean): Readonly<ElementDesiredSnapshot> {
    return this.#update({ connected });
  }

  public setTerminal(terminal: boolean): Readonly<ElementDesiredSnapshot> {
    return this.#update({ terminal, ...(terminal ? { connected: false } : {}) });
  }

  public enterRealm(): Readonly<ElementDesiredSnapshot> {
    return this.#update({
      realmSequence: this.#next(this.#snapshot.realmSequence, "realm sequence")
    });
  }

  public setDocumentVisible(
    visible: boolean,
    restored: boolean
  ): Readonly<ElementDesiredSnapshot> {
    return this.#update({
      documentVisible: visible,
      ...(restored ? {
        bfcacheRestoreSequence: this.#next(
          this.#snapshot.bfcacheRestoreSequence,
          "bfcache restore sequence"
        )
      } : {})
    });
  }

  public setIntersection(intersecting: boolean): Readonly<ElementDesiredSnapshot> {
    return this.#update({ intersecting });
  }

  public setObserverSupported(supported: boolean): Readonly<ElementDesiredSnapshot> {
    return this.#update({
      observerSupported: supported,
      ...(!supported ? { intersecting: false } : {})
    });
  }

  public setBox(box: Readonly<{ width: number; height: number }>): Readonly<ElementDesiredSnapshot> {
    if (
      !Number.isFinite(box.width) || box.width < 0 ||
      !Number.isFinite(box.height) || box.height < 0
    ) throw new RangeError("element presentation box is invalid");
    return this.#update({
      box: Object.freeze({ width: box.width, height: box.height }),
      positiveBox: box.width > 0 && box.height > 0
    });
  }

  public setDpr(value: number): Readonly<ElementDesiredSnapshot> {
    if (!Number.isFinite(value) || value <= 0) throw new RangeError("element DPR is invalid");
    return this.#update({ dpr: value });
  }

  public setHostReduced(value: boolean | null): Readonly<ElementDesiredSnapshot> {
    return this.#update({ hostReducedMotion: value });
  }

  public setManualPlaying(value: boolean): Readonly<ElementDesiredSnapshot> {
    return this.#update({
      manualPlaying: value,
      playSequence: this.#next(this.#snapshot.playSequence, "play sequence")
    });
  }

  public requestState(name: string): Readonly<ElementDesiredSnapshot> {
    this.#stateSequence = this.#next(this.#stateSequence, "state intent sequence");
    return this.#update({
      stateIntent: Object.freeze({ name, sequence: this.#stateSequence })
    });
  }

  /** Semantic absent-state intent; each source resolves it to its own initial state. */
  public requestInitialState(): Readonly<ElementDesiredSnapshot> {
    this.#stateSequence = this.#next(this.#stateSequence, "state intent sequence");
    return this.#update({
      stateIntent: Object.freeze({ name: null, sequence: this.#stateSequence })
    });
  }

  public clearStateIntent(): Readonly<ElementDesiredSnapshot> {
    return this.#update({ stateIntent: null });
  }

  public restoreStateIntent(
    intent: Readonly<{ name: string | null; sequence: number }> | null
  ): Readonly<ElementDesiredSnapshot> {
    return this.#update({ stateIntent: intent });
  }

  public setInteractionTarget(target: Element | null): Readonly<ElementDesiredSnapshot> {
    return this.#update({ interactionTarget: target });
  }

  #update(
    patch: Partial<Omit<ElementDesiredSnapshot, "revision" | "effectivelyVisible">>
  ): Readonly<ElementDesiredSnapshot> {
    this.#snapshot = freezeSnapshot({
      ...this.#snapshot,
      ...patch,
      revision: this.#next(this.#snapshot.revision, "revision")
    });
    return this.#snapshot;
  }

  #next(value: number, name: string): number {
    if (value >= this.#maximumSequence) {
      throw new Error(`element ${name} is exhausted`);
    }
    return value + 1;
  }
}

function freezeSnapshot(input: Omit<ElementDesiredSnapshot, "effectivelyVisible"> & {
  readonly effectivelyVisible?: boolean;
}): Readonly<ElementDesiredSnapshot> {
  const effectivelyVisible = input.connected && !input.terminal &&
    input.documentVisible && input.intersecting && input.positiveBox;
  return Object.freeze({ ...input, effectivelyVisible });
}

function freezeConfiguration(
  configuration: Readonly<ElementConfiguration>
): Readonly<ElementConfiguration> {
  return Object.freeze({
    ...configuration,
    sourceCandidates: Object.freeze(configuration.sourceCandidates.map((candidate) =>
      Object.freeze({ ...candidate })
    ))
  });
}
