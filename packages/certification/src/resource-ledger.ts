export interface CertificationResourceSnapshot {
  readonly ordinal: number;
  readonly phase: string;
  readonly counters: Readonly<Record<string, number>>;
}

export class CertificationResourceLedger {
  readonly #maximumSnapshots: number;
  readonly #snapshots: CertificationResourceSnapshot[] = [];

  public constructor(maximumSnapshots = 10_000) {
    if (!Number.isSafeInteger(maximumSnapshots) || maximumSnapshots < 1 || maximumSnapshots > 100_000) throw new RangeError("maximumSnapshots is invalid");
    this.#maximumSnapshots = maximumSnapshots;
  }

  public append(snapshot: CertificationResourceSnapshot): void {
    if (this.#snapshots.length >= this.#maximumSnapshots) throw new RangeError("resource snapshot limit exceeded");
    if (!Number.isSafeInteger(snapshot.ordinal) || snapshot.ordinal < 0 || snapshot.ordinal <= (this.#snapshots.at(-1)?.ordinal ?? -1)) throw new RangeError("resource ordinal must increase strictly");
    if (snapshot.phase.length === 0 || snapshot.phase.length > 128) throw new RangeError("resource phase is invalid");
    if (Object.keys(snapshot.counters).length > 256) throw new RangeError("resource counter count exceeded");
    const counters: Record<string, number> = Object.create(null) as Record<string, number>;
    for (const [name, value] of Object.entries(snapshot.counters)) {
      if (!/^[a-z][a-z0-9.-]{0,127}$/u.test(name)) throw new TypeError(`invalid resource counter: ${name}`);
      if (!Number.isSafeInteger(value) || value < 0) throw new RangeError(`resource counter ${name} is invalid`);
      counters[name] = value;
    }
    this.#snapshots.push(Object.freeze({ ordinal: snapshot.ordinal, phase: snapshot.phase, counters: Object.freeze(counters) }));
  }

  public snapshot(): readonly CertificationResourceSnapshot[] {
    return Object.freeze(this.#snapshots.map((snapshot) => Object.freeze({ ...snapshot, counters: Object.freeze({ ...snapshot.counters }) })));
  }
}
