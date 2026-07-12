import { runtimeFixtureModelFromManifest } from "../src/runtime-scenario-ledger.js";

export const TEST_FIXTURE_DIGEST = "b".repeat(64);
export const TEST_RUNTIME_FIXTURE = runtimeFixtureModelFromManifest({
  frameRate: { numerator: 30, denominator: 1 }, initialState: "idle",
  units: [
    bodyUnit("idle-body", "loop"), bodyUnit("hover-body", "loop"), bodyUnit("finite-body", "finite"), bodyUnit("held-body", "finite"),
    { id: "done-body", kind: "body", frameCount: 8, playback: "loop", ports: [{ id: "default", entryFrame: 0, portalFrames: [0] }] },
    { id: "hover-shift", kind: "reversible", frameCount: 4 }, { id: "loading-bridge", kind: "bridge", frameCount: 2 }
  ],
  states: [{ id: "idle", bodyUnit: "idle-body" }, { id: "hover", bodyUnit: "hover-body" }, { id: "finite", bodyUnit: "finite-body" }, { id: "held", bodyUnit: "held-body" }, { id: "done", bodyUnit: "done-body" }],
  edges: [
    edge("idle-hover", "idle", "hover", "portal", { kind: "reversible", unit: "hover-shift", direction: "forward" }),
    edge("hover-idle", "hover", "idle", "portal", { kind: "reversible", unit: "hover-shift", direction: "reverse", reverseOf: "idle-hover" }),
    edge("idle-finite", "idle", "finite", "portal", { kind: "locked", unit: "loading-bridge" }),
    edge("finite-held", "finite", "held", "portal"), edge("held-done", "held", "done", "finish"), edge("done-idle", "done", "idle", "cut"), edge("held-idle", "held", "idle", "portal")
  ]
});

function bodyUnit(id: string, playback: "loop" | "finite") { return { id, kind: "body", frameCount: 8, playback, ports: [{ id: "default", entryFrame: 0, portalFrames: [0, 1, 2, 3, 4, 5, 6, 7] }] }; }
function edge(id: string, from: string, to: string, type: "portal" | "finish" | "cut", transition?: Record<string, unknown>) { return { id, from, to, trigger: id === "held-done" ? { type: "completion" } : { type: "event", name: id }, start: { type, ...(type === "portal" ? { sourcePort: "default" } : {}), targetPort: "default", maxWaitFrames: type === "cut" ? 1 : 12 }, ...(transition === undefined ? {} : { transition }) }; }

export function createRawScenarioLedger(scenario: Readonly<{ readonly id: string; readonly repetition: number; readonly seed: number }>): any {
  const trace = scenarioTrace(scenario.id);
  const lastTraceIndex = Math.max(0, ...trace.frames.map(({ traceIndex }) => traceIndex), ...trace.graphEvents.map(({ traceIndex }) => traceIndex));
  return {
    schemaVersion: "1.0", ledgerKind: "runtime-scenario", candidateManifestDigest: "a".repeat(64), fixtureDigest: TEST_FIXTURE_DIGEST,
    scenarioId: scenario.id, repetition: scenario.repetition, seed: scenario.seed, idealContentFrameIntervalMicroseconds: 33_333,
    frames: trace.frames, operations: trace.operations, graphEvents: trace.graphEvents,
    terminalTrace: { lastTraceIndex, contentTickRecords: trace.frames.length, cumulativeUnderflows: trace.frames.at(-1)?.cumulativeUnderflows ?? 0 },
    counterBaseline: counters(), counterTerminal: counters(),
    resourceEvents: [
      { eventOrdinal: 0, atMicroseconds: 0, kind: "acquired", resourceId: "player-1", resourceBytes: 1_024, ownedResources: 1, ownedBytes: 1_024 },
      { eventOrdinal: 1, atMicroseconds: 1, kind: "retired", resourceId: "player-1", resourceBytes: 1_024, ownedResources: 0, ownedBytes: 0 }
    ],
    cleanupReceipt: { reason: "dispose", retiredResourceIds: ["player-1"], ownedResources: 0, ownedBytes: 0, liveWorkers: 0, openFrames: 0, pendingLoads: 0, activeLeases: 0, stalePublications: 0 }
  };
}

function scenarioTrace(id: string): Readonly<{ frames: any[]; graphEvents: any[]; operations: any[] }> {
  if (id === "terminal-settlement") return { frames: [], graphEvents: [], operations: [] };
  if (id === "loop-1000") return loopTrace();
  if (id === "all-routes-1000") return routeTrace(1_000, false);
  if (id === "portal-1000") return routeTrace(1_000, true);
  if (id === "active-inverse-1000") return inverseTrace();
  if (id === "rapid-input-10000") return rapidTrace();
  throw new TypeError(`unknown generic scenario ${id}`);
}

class TraceBuilder {
  public readonly frames: any[] = [];
  public readonly graphEvents: any[] = [];
  #nextTrace = 0; #nextPresentation = 1; #nextGraphEvent = 0; #timeOffset = 0;
  public setTimeOffset(value: number): void { this.#timeOffset = value; }
  public graphRecord(effects: readonly Record<string, unknown>[]): void { const traceIndex = this.#nextTrace++; for (const effect of effects) this.graphEvents.push({ eventOrdinal: this.#nextGraphEvent++, traceIndex, effect }); }
  public frame(overrides: Record<string, unknown>, effects: readonly Record<string, unknown>[] = []): void {
    const traceIndex = this.#nextTrace++; const presentationOrdinal = this.#nextPresentation++;
    for (const effect of effects) this.graphEvents.push({ eventOrdinal: this.#nextGraphEvent++, traceIndex, effect });
    this.frames.push(rawFrame(traceIndex, presentationOrdinal, this.#timeOffset, overrides));
  }
}

function loopTrace() {
  const builder = new TraceBuilder(); let instance = 0; builder.frame(body("idle", "idle-body", 0, instance));
  for (let loop = 0; loop < 1_000; loop += 1) for (let local = 1; local <= 8; local += 1) { if (local === 8) instance += 1; builder.frame(body("idle", "idle-body", local % 8, instance)); }
  return { frames: builder.frames, graphEvents: builder.graphEvents, operations: [] };
}

function routeTrace(minimum: number, portalsOnly: boolean) {
  const builder = new TraceBuilder(); const state = { id: "idle", unit: "idle-body", local: 0, instance: 0 };
  builder.frame(body(state.id, state.unit, state.local, state.instance));
  const routeIds = portalsOnly ? ["idle-hover", "hover-idle", "idle-finite", "finite-held", "held-idle"] : ["idle-hover", "hover-idle", "idle-finite", "finite-held", "held-done", "done-idle"];
  let routeCount = 0; let sequence = 0;
  while (routeCount < minimum) {
    for (const edgeId of routeIds) {
      if (routeCount >= minimum) break;
      const fixtureEdge = TEST_RUNTIME_FIXTURE.edges.find(({ id }) => id === edgeId)!;
      if (state.id !== fixtureEdge.from) throw new Error(`route trace state drift: ${state.id}/${edgeId}`);
      const desired = desiredSourcePosition(fixtureEdge.id, routeCount, state.local);
      advanceBody(builder, state, desired);
      if (portalsOnly && fixtureEdge.id === "held-idle" && desired === 7) builder.frame(body(state.id, state.unit, state.local, state.instance));
      appendRoute(builder, state, fixtureEdge, sequence++);
      routeCount += 1;
    }
  }
  return { frames: builder.frames, graphEvents: builder.graphEvents, operations: [] };
}

function desiredSourcePosition(fixtureEdgeId: string, occurrence: number, current: number): number {
  if (fixtureEdgeId === "held-done") return 7;
  if (fixtureEdgeId === "done-idle") return current;
  if (fixtureEdgeId === "finite-held" || fixtureEdgeId === "held-idle") return occurrence % 8;
  return occurrence % 8;
}

function advanceBody(builder: TraceBuilder, state: { id: string; unit: string; local: number; instance: number }, desired: number): void {
  const unit = TEST_RUNTIME_FIXTURE.units.find(({ id }) => id === state.unit)!;
  if (unit.playback === "finite" && desired < state.local) throw new Error("finite trace cannot rewind");
  while (state.local !== desired) {
    if (unit.playback === "loop" && state.local === unit.frameCount - 1) { state.local = 0; state.instance += 1; }
    else state.local = Math.min(state.local + 1, unit.frameCount - 1);
    builder.frame(body(state.id, state.unit, state.local, state.instance));
  }
}

function appendRoute(builder: TraceBuilder, state: { id: string; unit: string; local: number; instance: number }, fixtureEdge: (typeof TEST_RUNTIME_FIXTURE.edges)[number], sequence: number, includeRequested = true): void {
  const start = { type: "transitionstart", edgeId: fixtureEdge.id, from: fixtureEdge.from, to: fixtureEdge.to, sequence };
  const requested = { type: "requestedstatechange", from: fixtureEdge.from, to: fixtureEdge.to, sequence };
  const end = { type: "transitionend", edgeId: fixtureEdge.id, from: fixtureEdge.from, to: fixtureEdge.to };
  const visual = { type: "visualstatechange", from: fixtureEdge.from, to: fixtureEdge.to };
  if (fixtureEdge.transition === null) {
    builder.graphRecord([...(includeRequested ? [requested] : []), start, visual, end]);
    const target = TEST_RUNTIME_FIXTURE.states.find(({ id }) => id === fixtureEdge.to)!;
    state.id = fixtureEdge.to; state.unit = target.bodyUnit; state.local = 0; state.instance = 0;
    builder.frame(body(state.id, state.unit, 0, 0));
    return;
  }
  builder.graphRecord([...(includeRequested ? [requested] : []), start]);
  const unit = TEST_RUNTIME_FIXTURE.units.find(({ id }) => id === fixtureEdge.transition!.unit)!;
  for (let offset = 0; offset < unit.frameCount; offset += 1) {
    const local = fixtureEdge.transition.direction === "reverse" ? unit.frameCount - 1 - offset : offset;
    builder.frame(transition(fixtureEdge.id, fixtureEdge.transition.kind, fixtureEdge.transition.direction, unit.id, local));
  }
  const target = TEST_RUNTIME_FIXTURE.states.find(({ id }) => id === fixtureEdge.to)!;
  state.id = fixtureEdge.to; state.unit = target.bodyUnit; state.local = 0; state.instance = 0;
  builder.frame(body(state.id, state.unit, 0, 0), [visual, end]);
}

function inverseTrace() {
  const builder = new TraceBuilder(); let sequence = 0; let edgeId = "idle-hover"; let direction: "forward" | "reverse" = "forward"; let local = 0;
  builder.frame(transition(edgeId, "reversible", direction, "hover-shift", local)); local = 1; builder.frame(transition(edgeId, "reversible", direction, "hover-shift", local));
  for (let index = 0; index < 1_000; index += 1) {
    const nextEdge = edgeId === "idle-hover" ? "hover-idle" : "idle-hover"; const nextDirection: "forward" | "reverse" = direction === "forward" ? "reverse" : "forward"; const nextLocal = local + (nextDirection === "forward" ? 1 : -1);
    const fixtureEdge = TEST_RUNTIME_FIXTURE.edges.find(({ id }) => id === nextEdge)!;
    builder.graphRecord([{ type: "requestedstatechange", from: fixtureEdge.from, to: fixtureEdge.to, sequence }, { type: "transitionstart", edgeId: nextEdge, from: fixtureEdge.from, to: fixtureEdge.to, sequence }]); sequence += 1;
    edgeId = nextEdge; direction = nextDirection; local = nextLocal;
    builder.frame(transition(edgeId, "reversible", direction, "hover-shift", local, { routeReady: true }));
  }
  return { frames: builder.frames, graphEvents: builder.graphEvents, operations: [] };
}

function rapidTrace() {
  const builder = new TraceBuilder(); builder.setTimeOffset(100_000);
  builder.frame(body("idle", "idle-body", 0, 0)); builder.frame(body("idle", "idle-body", 1, 0));
  const operations: any[] = []; let eventOrdinal = 0; let requestedState = "idle";
  const push = (event: Record<string, unknown>) => operations.push({ eventOrdinal, atMicroseconds: eventOrdinal++, ...event });
  for (let operationOrdinal = 0; operationOrdinal < 10_000; operationOrdinal += 1) {
    const target = (["hover", "idle", "finite"] as const)[operationOrdinal % 3]!;
    const requested = { type: "requestedstatechange", from: requestedState, to: target, sequence: operationOrdinal };
    builder.graphRecord([requested]);
    if (operationOrdinal < 1_000) push({ kind: "headed-dispatch", operationOrdinal, eventType: operationOrdinal % 2 === 0 ? "pointerenter" : "pointerleave" });
    push({ kind: "input", operationOrdinal, inputSequence: operationOrdinal, target });
    push({ kind: "dom-event", name: "requestedstatechange", from: requestedState, to: target, edge: null, sequence: operationOrdinal });
    push({ kind: "promise", operationOrdinal, status: operationOrdinal === 9_999 ? "fulfilled" : "rejected", errorName: operationOrdinal === 9_999 ? null : "AbortError" });
    requestedState = target;
  }
  const edge = TEST_RUNTIME_FIXTURE.edges.find(({ id }) => id === "idle-hover")!; appendRoute(builder, { id: "idle", unit: "idle-body", local: 1, instance: 0 }, edge, 9_999, false);
  push({ kind: "dom-event", name: "transitionstart", from: "idle", to: "hover", edge: "idle-hover", sequence: 9_999 });
  push({ kind: "dom-event", name: "visualstatechange", from: "idle", to: "hover", edge: null, sequence: null });
  push({ kind: "dom-event", name: "transitionend", from: "idle", to: "hover", edge: "idle-hover", sequence: null });
  return { frames: builder.frames, graphEvents: builder.graphEvents, operations };
}

function rawFrame(traceIndex: number, presentationOrdinal: number, timeOffset: number, overrides: Record<string, unknown>): any {
  const unit = String(overrides.mediaUnit); const local = Number(overrides.mediaLocalFrame); const instance = Number(overrides.mediaUnitInstance); const state = overrides.mediaState as string | null; const edge = overrides.mediaEdge as string | null;
  return { traceIndex, presentationOrdinal, rationalDeadlineMicroseconds: presentationOrdinal * 33_333, eligibleAnimationFrameOrdinal: presentationOrdinal, callbackStartMicroseconds: timeOffset + presentationOrdinal * 1_000, canvasSubmissionCompleteMicroseconds: timeOffset + presentationOrdinal * 1_000 + 100, graphContentOrdinal: presentationOrdinal - 1, graphRequestedState: overrides.graphRequestedState ?? state, graphVisualState: overrides.graphVisualState ?? state, graphPendingEdge: null, graphActiveEdge: edge, graphPresentationKind: overrides.graphPresentationKind, graphPresentationState: state, graphPresentationEdge: edge, graphPresentationUnit: unit, graphPresentationFrame: local, graphPresentationDirection: overrides.graphPresentationDirection ?? null, routeReady: overrides.routeReady ?? false, selectedBoundary: edge, mediaState: state, mediaEdge: edge, mediaUnit: unit, mediaLocalFrame: local, mediaUnitInstance: instance, mediaIntendedPresentationOrdinal: presentationOrdinal, submittedCursors: [{ unit, unitInstance: instance, localFrame: local }], decodeLeadFrames: 6, cumulativeUnderflows: 0, ...overrides };
}

function body(state: string, unit: string, localFrame: number, unitInstance: number) { return { mediaState: state, mediaEdge: null, mediaUnit: unit, mediaLocalFrame: localFrame, mediaUnitInstance: unitInstance, graphPresentationKind: "body", graphPresentationDirection: null }; }
function transition(edgeId: string, kind: "locked" | "reversible", direction: "forward" | "reverse" | null, unit: string, localFrame: number, extra: Record<string, unknown> = {}) { return { mediaState: null, mediaEdge: edgeId, mediaUnit: unit, mediaLocalFrame: localFrame, mediaUnitInstance: 0, graphPresentationKind: kind, graphPresentationDirection: direction, graphRequestedState: TEST_RUNTIME_FIXTURE.edges.find(({ id }) => id === edgeId)!.to, graphVisualState: TEST_RUNTIME_FIXTURE.edges.find(({ id }) => id === edgeId)!.from, ...extra }; }
function counters() { return { configure: 1, reset: 0, flush: 0, reconfigure: 0, seek: 0, stalePublications: 0, capViolations: 0, untrackedOwnedBytes: 0, terminalOwnedResources: 0 }; }
