export interface RuntimeFixtureModel {
  readonly frameRateNumerator: number;
  readonly frameRateDenominator: number;
  readonly initialState: string;
  readonly states: readonly Readonly<{ readonly id: string; readonly bodyUnit: string }>[];
  readonly units: readonly Readonly<{
    readonly id: string;
    readonly kind: "body" | "bridge" | "reversible" | "one-shot";
    readonly frameCount: number;
    readonly playback: "loop" | "finite" | null;
    readonly ports: readonly Readonly<{ readonly id: string; readonly entryFrame: number; readonly portalFrames: readonly number[] }>[];
  }>[];
  readonly edges: readonly Readonly<{
    readonly id: string;
    readonly from: string;
    readonly to: string;
    readonly trigger: Readonly<{ readonly type: "event" | "completion"; readonly name: string | null }> | null;
    readonly start: Readonly<{
      readonly type: "portal" | "finish" | "cut";
      readonly sourcePort: string | null;
      readonly targetPort: string;
      readonly maxWaitFrames: number;
    }>;
    readonly transition: Readonly<{
      readonly kind: "locked" | "reversible";
      readonly unit: string;
      readonly direction: "forward" | "reverse" | null;
      readonly reverseOf: string | null;
    }> | null;
  }>[];
}

/** Extracts only the graph authority needed by certification from a validated compiled manifest. */
export function runtimeFixtureModelFromManifest(input: unknown): RuntimeFixtureModel {
  const manifest = record(input, "$fixture");
  const frameRate = record(manifest.frameRate, "$fixture.frameRate");
  const units = array(manifest.units, "$fixture.units", 4_096).map((value, index) => {
    const path = `$fixture.units[${String(index)}]`;
    const unit = record(value, path);
    const kind = enumeration(unit.kind, ["body", "bridge", "reversible", "one-shot"] as const, `${path}.kind`);
    const frameCount = positiveInteger(unit.frameCount, `${path}.frameCount`);
    const ports = kind === "body" ? array(unit.ports, `${path}.ports`, 4_096).map((portValue, portIndex) => {
      const portPath = `${path}.ports[${String(portIndex)}]`;
      const port = record(portValue, portPath);
      const portalFrames = array(port.portalFrames, `${portPath}.portalFrames`, 4_096).map((frame, frameIndex) => boundedInteger(frame, `${portPath}.portalFrames[${String(frameIndex)}]`, 0, frameCount - 1));
      unique(portalFrames, `${portPath}.portalFrames`);
      return Object.freeze({ id: text(port.id, `${portPath}.id`), entryFrame: boundedInteger(port.entryFrame, `${portPath}.entryFrame`, 0, frameCount - 1), portalFrames: Object.freeze(portalFrames) });
    }) : [];
    return Object.freeze({ id: text(unit.id, `${path}.id`), kind, frameCount, playback: kind === "body" ? enumeration(unit.playback, ["loop", "finite"] as const, `${path}.playback`) : null, ports: Object.freeze(ports) });
  });
  unique(units.map(({ id }) => id), "$fixture.units.id");
  const states = array(manifest.states, "$fixture.states", 4_096).map((value, index) => {
    const state = record(value, `$fixture.states[${String(index)}]`);
    return Object.freeze({ id: text(state.id, `$fixture.states[${String(index)}].id`), bodyUnit: text(state.bodyUnit, `$fixture.states[${String(index)}].bodyUnit`) });
  });
  unique(states.map(({ id }) => id), "$fixture.states.id");
  const unitIds = new Set(units.map(({ id }) => id));
  for (const state of states) if (!unitIds.has(state.bodyUnit)) throw new TypeError(`$fixture state ${state.id} references an unknown body unit`);
  const edges = array(manifest.edges, "$fixture.edges", 4_096).map((value, index) => {
    const path = `$fixture.edges[${String(index)}]`;
    const edge = record(value, path);
    const startInput = record(edge.start, `${path}.start`);
    const startType = enumeration(startInput.type, ["portal", "finish", "cut"] as const, `${path}.start.type`);
    const transitionInput = edge.transition === undefined ? null : record(edge.transition, `${path}.transition`);
    const triggerInput = edge.trigger === undefined ? null : record(edge.trigger, `${path}.trigger`);
    const transition = transitionInput === null ? null : Object.freeze({
      kind: enumeration(transitionInput.kind, ["locked", "reversible"] as const, `${path}.transition.kind`),
      unit: text(transitionInput.unit ?? transitionInput.unitId, `${path}.transition.unit`),
      direction: transitionInput.kind === "reversible" ? enumeration(transitionInput.direction, ["forward", "reverse"] as const, `${path}.transition.direction`) : null,
      reverseOf: nullableText(transitionInput.reverseOf ?? null, `${path}.transition.reverseOf`)
    });
    if (transition !== null && !unitIds.has(transition.unit)) throw new TypeError(`${path}.transition references an unknown unit`);
    return Object.freeze({
      id: text(edge.id, `${path}.id`), from: text(edge.from, `${path}.from`), to: text(edge.to, `${path}.to`),
      trigger: triggerInput === null ? null : Object.freeze({ type: enumeration(triggerInput.type, ["event", "completion"] as const, `${path}.trigger.type`), name: triggerInput.type === "event" ? text(triggerInput.name, `${path}.trigger.name`) : null }),
      start: Object.freeze({ type: startType, sourcePort: startType === "portal" ? text(startInput.sourcePort, `${path}.start.sourcePort`) : null, targetPort: text(startInput.targetPort, `${path}.start.targetPort`), maxWaitFrames: nonnegativeInteger(startInput.maxWaitFrames, `${path}.start.maxWaitFrames`) }),
      transition
    });
  });
  unique(edges.map(({ id }) => id), "$fixture.edges.id");
  const stateIds = new Set(states.map(({ id }) => id));
  for (const edge of edges) if (!stateIds.has(edge.from) || !stateIds.has(edge.to)) throw new TypeError(`$fixture edge ${edge.id} references an unknown state`);
  const model = Object.freeze({ frameRateNumerator: positiveInteger(frameRate.numerator, "$fixture.frameRate.numerator"), frameRateDenominator: positiveInteger(frameRate.denominator, "$fixture.frameRate.denominator"), initialState: text(manifest.initialState, "$fixture.initialState"), states: Object.freeze(states), units: Object.freeze(units), edges: Object.freeze(edges) });
  if (!stateIds.has(model.initialState)) throw new TypeError("$fixture.initialState is unknown");
  return model;
}

function array(value: unknown, path: string, maximum: number): readonly unknown[] { if (!Array.isArray(value) || value.length > maximum) throw new TypeError(`${path} must be an array of at most ${String(maximum)} items`); return value; }
function record(value: unknown, path: string): Record<string, unknown> { if (value === null || typeof value !== "object" || Array.isArray(value)) throw new TypeError(`${path} must be an object`); return value as Record<string, unknown>; }
function text(value: unknown, path: string): string { if (typeof value !== "string" || value.length < 1 || value.length > 128 || !/^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/u.test(value)) throw new TypeError(`${path} is invalid`); return value; }
function nullableText(value: unknown, path: string): string | null { return value === null ? null : text(value, path); }
function nonnegativeInteger(value: unknown, path: string): number { if (!Number.isSafeInteger(value) || (value as number) < 0) throw new RangeError(`${path} must be a nonnegative safe integer`); return value as number; }
function positiveInteger(value: unknown, path: string): number { const result = nonnegativeInteger(value, path); if (result === 0) throw new RangeError(`${path} must be positive`); return result; }
function boundedInteger(value: unknown, path: string, minimum: number, maximum: number): number { const result = nonnegativeInteger(value, path); if (result < minimum || result > maximum) throw new RangeError(`${path} must be ${String(minimum)}..${String(maximum)}`); return result; }
function enumeration<const T extends readonly string[]>(value: unknown, values: T, path: string): T[number] { if (typeof value !== "string" || !values.includes(value)) throw new TypeError(`${path} is invalid`); return value as T[number]; }
function unique(values: readonly (string | number)[], path: string): void { if (new Set(values).size !== values.length) throw new TypeError(`${path} must be unique`); }
