import { quantileNearestRank } from "./runtime-criteria.js";
import { REQUIRED_RUNTIME_SCENARIOS } from "./scenario-contract.js";
import type { RuntimeFixtureModel } from "./runtime-fixture-model.js";
import type { RawRuntimeGraphEffect, RawRuntimeGraphEvent, RawRuntimeOperationEvent, RawRuntimeScenarioFrame, RuntimeScenarioLedger, RuntimeScenarioLedgerEvaluation, RuntimeScenarioLedgerExpectation } from "./runtime-scenario-parser.js";

export const REQUIRED_ROUTE_CLASSES = Object.freeze([
  "portal:reversible",
  "portal:locked",
  "portal:none",
  "finish:none",
  "cut:none"
] as const);
const COUNTER_KEYS = ["configure", "reset", "flush", "reconfigure", "seek", "stalePublications", "capViolations", "untrackedOwnedBytes", "terminalOwnedResources"] as const;

export interface RuntimeDisplayScheduleEntry {
  readonly presentationOrdinal: number;
  readonly contentOrdinal: number;
  readonly occurrenceOrdinal: number;
  readonly canvasSubmissionCompleteMicroseconds: number;
  readonly boundary: boolean;
}

/** Reuses the exact runtime derivation authority for independently observed refresh grading. */
export function deriveRuntimeDisplaySchedule(ledger: RuntimeScenarioLedger, fixture: RuntimeFixtureModel): readonly RuntimeDisplayScheduleEntry[] {
  const failures: string[] = [];
  const frames = deriveFrames(ledger.frames, fixture, failures);
  const boundaries = deriveBoundaries(frames.eligible, ledger.graphEvents, fixture, failures);
  validateConsecutiveMediaProgression(frames.eligible, boundaries, fixture, failures);
  if (failures.length > 0) throw new Error(`runtime display schedule is invalid: ${failures[0]}`);
  return Object.freeze(frames.eligible.map(({ raw }) => Object.freeze({
    presentationOrdinal: raw.presentationOrdinal,
    contentOrdinal: raw.graphContentOrdinal!,
    occurrenceOrdinal: raw.mediaUnitInstance!,
    canvasSubmissionCompleteMicroseconds: raw.canvasSubmissionCompleteMicroseconds!,
    boundary: boundaries.byOrdinal.has(raw.presentationOrdinal)
  })));
}

export function gradeRuntimeScenarioLedger(ledger: RuntimeScenarioLedger, expected: RuntimeScenarioLedgerExpectation): RuntimeScenarioLedgerEvaluation {
  const failures: string[] = [];
  if (expected.candidateManifestDigest !== undefined && ledger.candidateManifestDigest !== expected.candidateManifestDigest) failures.push("candidate-manifest-digest-mismatch");
  if (expected.fixtureDigest !== undefined && ledger.fixtureDigest !== expected.fixtureDigest) failures.push("fixture-digest-mismatch");
  if (expected.scenarioId !== undefined && ledger.scenarioId !== expected.scenarioId) failures.push("scenario-id-mismatch");
  if (expected.repetition !== undefined && ledger.repetition !== expected.repetition) failures.push("scenario-repetition-mismatch");
  if (expected.seed !== undefined && ledger.seed !== expected.seed) failures.push("scenario-seed-mismatch");
  const fixture = expected.fixture;
  if (fixture === undefined) failures.push("fixture-authority-missing");
  const ideal = fixture === undefined ? ledger.idealContentFrameIntervalMicroseconds : Math.round(fixture.frameRateDenominator * 1_000_000 / fixture.frameRateNumerator);
  if (ledger.idealContentFrameIntervalMicroseconds !== ideal) failures.push("fixture-frame-rate-mismatch");

  const derived = deriveFrames(ledger.frames, fixture, failures);
  const boundaries = fixture === undefined ? emptyBoundaries() : deriveBoundaries(derived.eligible, ledger.graphEvents, fixture, failures);
  if (fixture !== undefined) validateConsecutiveMediaProgression(derived.eligible, boundaries, fixture, failures);
  const intervals = derived.eligible.slice(1).map((frame, index) => ({
    frame,
    callbackInterval: frame.raw.callbackStartMicroseconds - derived.eligible[index]!.raw.callbackStartMicroseconds,
    submissionInterval: frame.raw.canvasSubmissionCompleteMicroseconds! - derived.eligible[index]!.raw.canvasSubmissionCompleteMicroseconds!
  }));
  for (const { frame, callbackInterval, submissionInterval } of intervals) if (callbackInterval < 0 || submissionInterval < 0) {
    failures.push(`inter-frame-clock-order:${String(frame.raw.presentationOrdinal)}`);
  }
  const nonBoundarySubmissionIntervals = intervals.filter(({ frame, submissionInterval }) => !boundaries.byOrdinal.has(frame.raw.presentationOrdinal) && submissionInterval >= 0).map(({ submissionInterval }) => submissionInterval);
  const thresholdMicroseconds = Math.max(ideal * 1.5, quantileNearestRank(nonBoundarySubmissionIntervals, 99, 100) + ideal * 0.5);
  let firstFailingOrdinal = derived.firstFailingOrdinal;
  for (const { frame, callbackInterval, submissionInterval } of intervals) {
    if (!boundaries.byOrdinal.has(frame.raw.presentationOrdinal) || callbackInterval < 0 || submissionInterval < 0) continue;
    if (submissionInterval > thresholdMicroseconds) failures.push(`boundary-submission-gap:${String(frame.raw.presentationOrdinal)}`);
    if (callbackInterval > thresholdMicroseconds) failures.push(`boundary-callback-gap:${String(frame.raw.presentationOrdinal)}`);
    if ((submissionInterval > thresholdMicroseconds || callbackInterval > thresholdMicroseconds) && firstFailingOrdinal === null) firstFailingOrdinal = frame.raw.presentationOrdinal;
  }
  if (ledger.frames.length > 0 && derived.eligible.length === 0) failures.push("eligible-frame-ledger-empty");
  if (derived.eligible.length > 1 && nonBoundarySubmissionIntervals.length === 0) failures.push("non-boundary-baseline-empty");

  let boundaryCount = 0;
  if (ledger.scenarioId === REQUIRED_RUNTIME_SCENARIOS.loop.id) {
    boundaryCount = boundaries.loop.length;
    if (boundaryCount < 1_000) failures.push("loop-boundaries-below-1000");
  } else if (ledger.scenarioId === REQUIRED_RUNTIME_SCENARIOS.routes.id) {
    boundaryCount = boundaries.routes.length;
    if (boundaryCount < 1_000) failures.push("route-boundaries-below-1000");
    const classes = new Set(boundaries.routes.map(({ routeClass }) => routeClass));
    for (const routeClass of REQUIRED_ROUTE_CLASSES) if (!classes.has(routeClass)) failures.push(`route-class-missing:${routeClass}`);
  } else if (ledger.scenarioId === REQUIRED_RUNTIME_SCENARIOS.inverse.id) {
    boundaryCount = boundaries.inverse.length;
    if (boundaryCount < 1_000) failures.push("inverse-boundaries-below-1000");
  } else if (ledger.scenarioId === REQUIRED_RUNTIME_SCENARIOS.portal.id) {
    boundaryCount = boundaries.portal.length;
    if (boundaryCount < 1_000) failures.push("portal-selections-below-1000");
    validatePortalCoverage(boundaries.portal, failures);
  }

  const operationCounts = validateOperations(ledger, derived.eligible, fixture, failures);
  validateCounters(ledger, failures);
  validateTerminalTrace(ledger, failures);
  validateResourceSettlement(ledger, failures);
  return Object.freeze({
    passed: failures.length === 0,
    boundaryCount,
    frameCount: ledger.frames.length,
    operationCount: operationCounts.operationCount,
    headedOperationCount: operationCounts.headedOperationCount,
    formatUnderflows: derived.formatUnderflows,
    firstFailingOrdinal,
    thresholdMicroseconds,
    failures: Object.freeze(failures)
  });
}

interface DerivedFrame { readonly raw: RawRuntimeScenarioFrame; }
interface PortalBoundary { readonly ordinal: number; readonly edgeId: string; readonly position: number; readonly legalPositions: readonly number[]; readonly origin: "loop" | "finite" | "held"; }
interface DerivedBoundaries {
  readonly byOrdinal: ReadonlySet<number>;
  readonly loop: readonly number[];
  readonly routes: readonly Readonly<{ readonly ordinal: number; readonly edgeId: string; readonly routeClass: string }>[];
  readonly inverse: readonly number[];
  readonly portal: readonly PortalBoundary[];
}

function deriveFrames(frames: readonly RawRuntimeScenarioFrame[], fixture: RuntimeFixtureModel | undefined, failures: string[]): Readonly<{ readonly eligible: readonly DerivedFrame[]; readonly formatUnderflows: number; readonly firstFailingOrdinal: number | null }> {
  const eligible: DerivedFrame[] = [];
  let priorTrace = -1;
  let priorPresentation = -1;
  let priorCallback = -1;
  let priorSubmission = -1;
  let priorUnderflows = 0;
  let formatUnderflows = 0;
  let firstFailingOrdinal: number | null = null;
  const unitById = fixture === undefined ? new Map<string, RuntimeFixtureModel["units"][number]>() : new Map(fixture.units.map((unit) => [unit.id, unit]));
  const stateById = fixture === undefined ? new Map<string, RuntimeFixtureModel["states"][number]>() : new Map(fixture.states.map((state) => [state.id, state]));
  const edgeById = fixture === undefined ? new Map<string, RuntimeFixtureModel["edges"][number]>() : new Map(fixture.edges.map((edge) => [edge.id, edge]));
  for (const frame of frames) {
    let failed = false;
    if (priorTrace >= 0 && frame.traceIndex <= priorTrace) { failures.push(`trace-index-order:${String(frame.traceIndex)}`); failed = true; }
    priorTrace = frame.traceIndex;
    if (frame.callbackStartMicroseconds < priorCallback) { failures.push(`callback-order:${String(frame.presentationOrdinal)}`); failed = true; }
    priorCallback = frame.callbackStartMicroseconds;
    if (frame.cumulativeUnderflows < priorUnderflows) { failures.push(`underflow-counter-regressed:${String(frame.presentationOrdinal)}`); failed = true; }
    const underflowDelta = frame.cumulativeUnderflows - priorUnderflows;
    priorUnderflows = frame.cumulativeUnderflows;
    const complete = frame.canvasSubmissionCompleteMicroseconds !== null && frame.graphContentOrdinal !== null && frame.mediaUnit !== null && frame.mediaLocalFrame !== null && frame.mediaUnitInstance !== null && frame.mediaIntendedPresentationOrdinal !== null && frame.graphPresentationKind !== null && frame.graphPresentationUnit !== null && frame.graphPresentationFrame !== null;
    if (!complete || underflowDelta > 0) {
      formatUnderflows += Math.max(1, underflowDelta);
      failures.push(`format-underflow:${String(frame.presentationOrdinal)}`);
      if (firstFailingOrdinal === null) firstFailingOrdinal = frame.presentationOrdinal;
      continue;
    }
    if (priorPresentation >= 0 && frame.presentationOrdinal !== priorPresentation + 1) { failures.push(`presentation-contiguity:${String(frame.presentationOrdinal)}`); failed = true; }
    priorPresentation = frame.presentationOrdinal;
    if (frame.canvasSubmissionCompleteMicroseconds! < frame.callbackStartMicroseconds || frame.canvasSubmissionCompleteMicroseconds! < priorSubmission) { failures.push(`submission-order:${String(frame.presentationOrdinal)}`); failed = true; }
    priorSubmission = frame.canvasSubmissionCompleteMicroseconds!;
    const required = frame.presentationOrdinal - 1;
    if (frame.graphContentOrdinal !== required) { failures.push(`content-identity:${String(frame.presentationOrdinal)}`); failed = true; }
    if (frame.mediaIntendedPresentationOrdinal !== frame.presentationOrdinal) { failures.push(`media-presentation-identity:${String(frame.presentationOrdinal)}`); failed = true; }
    if (frame.graphPresentationUnit !== frame.mediaUnit || frame.graphPresentationFrame !== frame.mediaLocalFrame || frame.graphPresentationEdge !== frame.mediaEdge || frame.graphPresentationState !== frame.mediaState) { failures.push(`graph-media-divergence:${String(frame.presentationOrdinal)}`); failed = true; }
    const unit = unitById.get(frame.mediaUnit!);
    if (fixture !== undefined && (unit === undefined || frame.mediaLocalFrame! >= unit.frameCount)) { failures.push(`fixture-media-identity:${String(frame.presentationOrdinal)}`); failed = true; }
    if (fixture !== undefined && frame.graphPresentationKind === "body") {
      const state = frame.graphPresentationState === null ? undefined : stateById.get(frame.graphPresentationState);
      if (state === undefined || state.bodyUnit !== frame.graphPresentationUnit || unit?.kind !== "body") { failures.push(`fixture-body-identity:${String(frame.presentationOrdinal)}`); failed = true; }
    } else if (fixture !== undefined && (frame.graphPresentationKind === "locked" || frame.graphPresentationKind === "reversible")) {
      const edge = frame.graphPresentationEdge === null ? undefined : edgeById.get(frame.graphPresentationEdge);
      if (edge?.transition?.unit !== frame.graphPresentationUnit || edge.transition.kind !== frame.graphPresentationKind || (edge.transition.kind === "reversible" && edge.transition.direction !== frame.graphPresentationDirection)) { failures.push(`fixture-transition-identity:${String(frame.presentationOrdinal)}`); failed = true; }
    }
    if (!frame.submittedCursors.some((cursor) => cursor.unit === frame.mediaUnit && cursor.unitInstance === frame.mediaUnitInstance && cursor.localFrame === frame.mediaLocalFrame)) { failures.push(`submission-cursor-identity:${String(frame.presentationOrdinal)}`); failed = true; }
    if (failed && firstFailingOrdinal === null) firstFailingOrdinal = frame.presentationOrdinal;
    eligible.push(Object.freeze({ raw: frame }));
  }
  return Object.freeze({ eligible: Object.freeze(eligible), formatUnderflows, firstFailingOrdinal });
}

function deriveBoundaries(frames: readonly DerivedFrame[], graphEvents: readonly RawRuntimeGraphEvent[], fixture: RuntimeFixtureModel, failures: string[]): DerivedBoundaries {
  const unitById = new Map(fixture.units.map((unit) => [unit.id, unit]));
  const stateById = new Map(fixture.states.map((state) => [state.id, state]));
  const edgeById = new Map(fixture.edges.map((edge) => [edge.id, edge]));
  const loop: number[] = [];
  const routes: { ordinal: number; edgeId: string; routeClass: string }[] = [];
  const inverse: number[] = [];
  const portal: PortalBoundary[] = [];
  const byOrdinal = new Set<number>();
  let priorEventTraceIndex = -1;
  let priorGraphEventOrdinal = -1;
  const requestedBySequence = new Map<number, Readonly<{ readonly traceIndex: number; readonly eventOrdinal: number }>>();
  const requestedEffectBySequence = new Map<number, Extract<RawRuntimeGraphEffect, { readonly type: "requestedstatechange" }>>();
  const transitionEndsByEdge = new Map<string, { traceIndex: number; eventOrdinal: number }[]>();
  const routeStarts: { traceIndex: number; eventOrdinal: number; effect: Extract<RawRuntimeGraphEffect, { readonly type: "transitionstart" }> }[] = [];
  for (const event of graphEvents) {
    if (event.eventOrdinal !== priorGraphEventOrdinal + 1) failures.push(`graph-event-ordinal:${String(event.eventOrdinal)}`);
    priorGraphEventOrdinal = event.eventOrdinal;
    if (event.traceIndex < priorEventTraceIndex) failures.push(`graph-event-order:${String(event.traceIndex)}`);
    priorEventTraceIndex = event.traceIndex;
    const effect = event.effect;
    if (effect.type === "requestedstatechange") {
      if (requestedBySequence.has(effect.sequence)) failures.push(`graph-request-sequence-duplicate:${String(effect.sequence)}`);
      requestedBySequence.set(effect.sequence, { traceIndex: event.traceIndex, eventOrdinal: event.eventOrdinal });
      requestedEffectBySequence.set(effect.sequence, effect);
      if (!stateById.has(effect.from) || !stateById.has(effect.to)) failures.push(`graph-request-state:${String(effect.sequence)}`);
    }
    else if (effect.type === "transitionstart") {
      routeStarts.push({ traceIndex: event.traceIndex, eventOrdinal: event.eventOrdinal, effect });
      const edge = edgeById.get(effect.edgeId);
      const request = requestedEffectBySequence.get(effect.sequence);
      if (edge === undefined || edge.from !== effect.from || edge.to !== effect.to || (request !== undefined && request.to !== effect.to)) failures.push(`graph-transition-start-identity:${String(effect.sequence)}`);
    }
    else if (effect.type === "transitionend") {
      const edge = edgeById.get(effect.edgeId);
      if (edge === undefined || edge.from !== effect.from || edge.to !== effect.to) failures.push(`graph-transition-end-identity:${effect.edgeId}`);
      const indexes = transitionEndsByEdge.get(effect.edgeId) ?? [];
      indexes.push({ traceIndex: event.traceIndex, eventOrdinal: event.eventOrdinal });
      transitionEndsByEdge.set(effect.edgeId, indexes);
    } else if (!stateById.has(effect.from) || !stateById.has(effect.to)) failures.push(`graph-visual-state:${String(event.traceIndex)}`);
  }
  for (let index = 1; index < frames.length; index += 1) {
    const previous = frames[index - 1]!.raw;
    const current = frames[index]!.raw;
    const unit = current.mediaUnit === null ? undefined : unitById.get(current.mediaUnit);
    if (unit?.kind === "body" && unit.playback === "loop" && current.mediaUnit === previous.mediaUnit && (current.mediaUnitInstance! > previous.mediaUnitInstance! || current.mediaLocalFrame! < previous.mediaLocalFrame!)) {
      loop.push(current.presentationOrdinal);
      byOrdinal.add(current.presentationOrdinal);
    }
  }
  let frameIndex = 0;
  for (const start of routeStarts) {
    while (frameIndex < frames.length && frames[frameIndex]!.raw.traceIndex < start.traceIndex) frameIndex += 1;
    const currentFrame = frames[frameIndex]?.raw;
    if (currentFrame === undefined) { failures.push(`route-start-without-frame:${String(start.traceIndex)}`); continue; }
    const edge = edgeById.get(start.effect.edgeId);
    if (edge === undefined || edge.from !== start.effect.from || edge.to !== start.effect.to) { failures.push(`fixture-route-identity:${String(currentFrame.presentationOrdinal)}`); continue; }
    const previousFrame = frames[frameIndex - 1]?.raw;
    const inversePair = previousFrame !== undefined && isInversePair(previousFrame, currentFrame, edge, edgeById);
    byOrdinal.add(currentFrame.presentationOrdinal);
    if (inversePair) {
      inverse.push(currentFrame.presentationOrdinal);
      validateInverseBoundary(previousFrame, currentFrame, edge, unitById, failures);
      continue;
    }
    const routeClass = `${edge.start.type}:${edge.transition?.kind ?? "none"}`;
    routes.push({ ordinal: currentFrame.presentationOrdinal, edgeId: edge.id, routeClass });
    const requestPosition = requestedBySequence.get(start.effect.sequence) ?? null;
    if (edge.trigger?.type === "event" && requestPosition === null) failures.push(`route-request-missing:${String(currentFrame.presentationOrdinal)}`);
    validateRouteBoundary(frames, frameIndex, edge, fixture, { traceIndex: start.traceIndex, eventOrdinal: start.eventOrdinal }, requestPosition, transitionEndsByEdge, failures);
    if (edge.start.type === "portal") {
      const sourceState = stateById.get(edge.from);
      const sourceUnit = sourceState === undefined ? undefined : unitById.get(sourceState.bodyUnit);
      const sourcePort = sourceUnit?.ports.find(({ id }) => id === edge.start.sourcePort);
      if (previousFrame === undefined || sourceUnit?.kind !== "body" || sourcePort === undefined || previousFrame.mediaUnit !== sourceUnit.id || previousFrame.mediaLocalFrame === null) {
        failures.push(`portal-source-identity:${String(currentFrame.presentationOrdinal)}`);
      } else {
        const beforeSource = frames[frameIndex - 2]?.raw;
        const repeatedTerminal = beforeSource !== undefined && beforeSource.mediaUnit === sourceUnit.id && beforeSource.mediaLocalFrame === sourceUnit.frameCount - 1 && previousFrame.mediaLocalFrame === sourceUnit.frameCount - 1;
        const origin = sourceUnit.playback === "loop" ? "loop" : repeatedTerminal ? "held" : "finite";
        portal.push(Object.freeze({ ordinal: currentFrame.presentationOrdinal, edgeId: edge.id, position: previousFrame.mediaLocalFrame, legalPositions: sourcePort.portalFrames, origin }));
        if (!sourcePort.portalFrames.includes(previousFrame.mediaLocalFrame)) failures.push(`portal-position-illegal:${String(currentFrame.presentationOrdinal)}`);
      }
    }
  }
  return Object.freeze({ byOrdinal, loop: Object.freeze(loop), routes: Object.freeze(routes), inverse: Object.freeze(inverse), portal: Object.freeze(portal) });
}

function validateRouteBoundary(frames: readonly DerivedFrame[], index: number, edge: RuntimeFixtureModel["edges"][number], fixture: RuntimeFixtureModel, routeStart: Readonly<{ readonly traceIndex: number; readonly eventOrdinal: number }>, request: Readonly<{ readonly traceIndex: number; readonly eventOrdinal: number }> | null, transitionEndsByEdge: ReadonlyMap<string, readonly Readonly<{ readonly traceIndex: number; readonly eventOrdinal: number }>[]>, failures: string[]): void {
  const current = frames[index]!.raw;
  const waitFrames = request === null ? 0 : index - upperBoundFrameTrace(frames, request.traceIndex, index);
  if (request !== null && (request.traceIndex > routeStart.traceIndex || (request.traceIndex === routeStart.traceIndex && request.eventOrdinal >= routeStart.eventOrdinal))) failures.push(`route-request-order:${String(current.presentationOrdinal)}`);
  if (waitFrames > edge.start.maxWaitFrames) failures.push(`route-wait-exceeded:${String(current.presentationOrdinal)}`);
  const unitById = new Map(fixture.units.map((unit) => [unit.id, unit]));
  const targetState = fixture.states.find(({ id }) => id === edge.to);
  const targetUnit = targetState === undefined ? undefined : unitById.get(targetState.bodyUnit);
  const targetPort = targetUnit?.ports.find(({ id }) => id === edge.start.targetPort);
  if (edge.transition === null) {
    if (current.graphPresentationKind !== "body" || current.graphPresentationState !== edge.to || current.graphPresentationUnit !== targetUnit?.id || current.graphPresentationFrame !== targetPort?.entryFrame) failures.push(`route-entry-port:${String(current.presentationOrdinal)}`);
    if (!hasTracePositionInRange(transitionEndsByEdge.get(edge.id), routeStart, current.traceIndex)) failures.push(`route-transition-end-missing:${String(current.presentationOrdinal)}`);
    return;
  }
  const transitionUnit = unitById.get(edge.transition.unit);
  if (transitionUnit === undefined) { failures.push(`route-transition-unit:${String(current.presentationOrdinal)}`); return; }
  for (let offset = 0; offset < transitionUnit.frameCount; offset += 1) {
    const transitionFrame = frames[index + offset]?.raw;
    const expectedFrame = edge.transition.direction === "reverse" ? transitionUnit.frameCount - 1 - offset : offset;
    if (transitionFrame === undefined || transitionFrame.graphPresentationUnit !== edge.transition.unit || transitionFrame.graphPresentationKind !== edge.transition.kind || transitionFrame.graphPresentationEdge !== edge.id || transitionFrame.graphPresentationFrame !== expectedFrame || (edge.transition.kind === "reversible" && transitionFrame.graphPresentationDirection !== edge.transition.direction)) {
      failures.push(`route-transition-progression:${String(current.presentationOrdinal)}:${String(offset)}`);
      return;
    }
  }
  const target = frames[index + transitionUnit.frameCount]?.raw;
  if (target === undefined || target.graphPresentationKind !== "body" || target.graphPresentationState !== edge.to || target.graphPresentationUnit !== targetUnit?.id || target.graphPresentationFrame !== targetPort?.entryFrame) failures.push(`route-target-port:${String(current.presentationOrdinal)}`);
  else if (!hasTracePositionInRange(transitionEndsByEdge.get(edge.id), routeStart, target.traceIndex)) failures.push(`route-transition-end-missing:${String(current.presentationOrdinal)}`);
}

function isInversePair(previous: RawRuntimeScenarioFrame, current: RawRuntimeScenarioFrame, currentEdge: RuntimeFixtureModel["edges"][number], edgeById: ReadonlyMap<string, RuntimeFixtureModel["edges"][number]>): boolean {
  if (previous.graphPresentationKind !== "reversible" || current.graphPresentationKind !== "reversible" || previous.graphPresentationEdge === null) return false;
  const previousEdge = edgeById.get(previous.graphPresentationEdge);
  return previousEdge?.transition?.kind === "reversible" && currentEdge.transition?.kind === "reversible" && previousEdge.transition.unit === currentEdge.transition.unit && previousEdge.transition.direction !== currentEdge.transition.direction && (currentEdge.transition.reverseOf === previousEdge.id || previousEdge.transition.reverseOf === currentEdge.id);
}

function validateInverseBoundary(previous: RawRuntimeScenarioFrame, current: RawRuntimeScenarioFrame, edge: RuntimeFixtureModel["edges"][number], unitById: ReadonlyMap<string, RuntimeFixtureModel["units"][number]>, failures: string[]): void {
  const transition = edge.transition;
  const unit = transition === null ? undefined : unitById.get(transition.unit);
  const expectedFrame = previous.graphPresentationFrame! + (transition?.direction === "forward" ? 1 : -1);
  const adjacent = current.graphPresentationFrame === expectedFrame;
  const runway = unit?.kind === "reversible" && current.routeReady === true && current.decodeLeadFrames !== null && current.decodeLeadFrames >= 1;
  if (transition?.kind !== "reversible" || current.graphPresentationDirection !== transition.direction || !adjacent || !runway) failures.push(`inverse-semantics:${String(current.presentationOrdinal)}`);
}

function validateConsecutiveMediaProgression(frames: readonly DerivedFrame[], boundaries: DerivedBoundaries, fixture: RuntimeFixtureModel, failures: string[]): void {
  const unitById = new Map(fixture.units.map((unit) => [unit.id, unit]));
  const routeOrdinals = new Set(boundaries.routes.map(({ ordinal }) => ordinal));
  const inverseOrdinals = new Set(boundaries.inverse);
  for (let index = 1; index < frames.length; index += 1) {
    const previous = frames[index - 1]!.raw;
    const current = frames[index]!.raw;
    if (routeOrdinals.has(current.presentationOrdinal) || inverseOrdinals.has(current.presentationOrdinal)) continue;
    const previousUnit = previous.graphPresentationUnit === null ? undefined : unitById.get(previous.graphPresentationUnit);
    if (previous.graphPresentationUnit === current.graphPresentationUnit && previousUnit !== undefined) {
      let expected = previous.graphPresentationFrame!;
      if (previousUnit.kind === "body") {
        expected = previousUnit.playback === "loop" ? (expected + 1) % previousUnit.frameCount : Math.min(expected + 1, previousUnit.frameCount - 1);
        const wrapped = previousUnit.playback === "loop" && expected === 0;
        const expectedInstance = previous.mediaUnitInstance! + (wrapped ? 1 : 0);
        if (current.mediaUnitInstance !== expectedInstance) failures.push(`media-unit-instance:${String(current.presentationOrdinal)}`);
      } else if (previousUnit.kind === "reversible") {
        expected += current.graphPresentationDirection === "reverse" ? -1 : 1;
        if (current.graphPresentationEdge !== previous.graphPresentationEdge || current.graphPresentationDirection !== previous.graphPresentationDirection) failures.push(`media-transition-identity:${String(current.presentationOrdinal)}`);
      }
      else expected += 1;
      if (current.graphPresentationFrame !== expected) failures.push(`media-progression:${String(current.presentationOrdinal)}`);
    } else if (previousUnit?.kind === "body") {
      failures.push(`media-unit-change-without-route:${String(current.presentationOrdinal)}`);
    }
  }
}

function hasTracePositionInRange(values: readonly Readonly<{ readonly traceIndex: number; readonly eventOrdinal: number }>[] | undefined, minimum: Readonly<{ readonly traceIndex: number; readonly eventOrdinal: number }>, maximumTraceIndex: number): boolean {
  if (values === undefined) return false;
  let low = 0; let high = values.length;
  while (low < high) { const middle = Math.floor((low + high) / 2); const value = values[middle]!; if (value.traceIndex < minimum.traceIndex || (value.traceIndex === minimum.traceIndex && value.eventOrdinal < minimum.eventOrdinal)) low = middle + 1; else high = middle; }
  return values[low] !== undefined && values[low]!.traceIndex <= maximumTraceIndex;
}

function upperBoundFrameTrace(frames: readonly DerivedFrame[], traceIndex: number, end: number): number {
  let low = 0; let high = end;
  while (low < high) { const middle = Math.floor((low + high) / 2); if (frames[middle]!.raw.traceIndex <= traceIndex) low = middle + 1; else high = middle; }
  return low;
}

function validatePortalCoverage(boundaries: readonly PortalBoundary[], failures: string[]): void {
  const origins = new Set(boundaries.map(({ origin }) => origin));
  for (const origin of ["loop", "finite", "held"] as const) if (!origins.has(origin)) failures.push(`portal-origin-missing:${origin}`);
  const byEdge = new Map<string, { legal: readonly number[]; seen: Set<number> }>();
  for (const boundary of boundaries) {
    const coverage = byEdge.get(boundary.edgeId) ?? { legal: boundary.legalPositions, seen: new Set<number>() };
    coverage.seen.add(boundary.position);
    byEdge.set(boundary.edgeId, coverage);
  }
  for (const [edgeId, coverage] of byEdge) for (const position of coverage.legal) if (!coverage.seen.has(position)) failures.push(`portal-position-missing:${edgeId}:${String(position)}`);
}

function validateOperations(ledger: RuntimeScenarioLedger, frames: readonly DerivedFrame[], fixture: RuntimeFixtureModel | undefined, failures: string[]): Readonly<{ readonly operationCount: number; readonly headedOperationCount: number }> {
  if (ledger.scenarioId !== REQUIRED_RUNTIME_SCENARIOS.rapidInput.id) {
    if (ledger.operations.length !== 0) failures.push("unexpected-operation-evidence");
    return Object.freeze({ operationCount: 0, headedOperationCount: 0 });
  }
  let priorEvent = -1;
  let priorTime = -1;
  for (const event of ledger.operations) {
    if (event.eventOrdinal !== priorEvent + 1) failures.push(`operation-event-order:${String(event.eventOrdinal)}`);
    if (event.atMicroseconds < priorTime) failures.push(`operation-event-clock:${String(event.eventOrdinal)}`);
    priorEvent = event.eventOrdinal;
    priorTime = event.atMicroseconds;
  }
  const inputs = ledger.operations.filter((event): event is Extract<RawRuntimeOperationEvent, { readonly kind: "input" }> => event.kind === "input");
  const headedDispatches = ledger.operations.filter((event): event is Extract<RawRuntimeOperationEvent, { readonly kind: "headed-dispatch" }> => event.kind === "headed-dispatch");
  const promises = ledger.operations.filter((event): event is Extract<RawRuntimeOperationEvent, { readonly kind: "promise" }> => event.kind === "promise");
  const domEvents = ledger.operations.filter((event): event is Extract<RawRuntimeOperationEvent, { readonly kind: "dom-event" }> => event.kind === "dom-event");
  const inputByOrdinal = new Map<number, (typeof inputs)[number]>();
  const inputBySequence = new Map<number, (typeof inputs)[number]>();
  const promiseByOrdinal = new Map<number, (typeof promises)[number]>();
  const headedByOrdinal = new Map<number, (typeof headedDispatches)[number]>();
  for (const input of inputs) {
    if (inputByOrdinal.has(input.operationOrdinal)) failures.push(`operation-duplicate-input:${String(input.operationOrdinal)}`);
    else inputByOrdinal.set(input.operationOrdinal, input);
    if (inputBySequence.has(input.inputSequence)) failures.push(`operation-duplicate-sequence:${String(input.inputSequence)}`);
    else inputBySequence.set(input.inputSequence, input);
  }
  for (const promise of promises) {
    if (promiseByOrdinal.has(promise.operationOrdinal)) failures.push(`operation-duplicate-promise:${String(promise.operationOrdinal)}`);
    else promiseByOrdinal.set(promise.operationOrdinal, promise);
  }
  for (const dispatch of headedDispatches) {
    if (headedByOrdinal.has(dispatch.operationOrdinal)) failures.push(`operation-duplicate-headed-dispatch:${String(dispatch.operationOrdinal)}`);
    else headedByOrdinal.set(dispatch.operationOrdinal, dispatch);
  }
  if (inputs.length < 10_000) failures.push("rapid-operations-below-10000");
  const headedOperationCount = headedByOrdinal.size;
  if (headedOperationCount < 1_000) failures.push("headed-operations-below-1000");
  const stateIds = new Set(fixture?.states.map(({ id }) => id) ?? []);
  const requestedBySequence = new Map<number, Extract<RawRuntimeGraphEffect, { readonly type: "requestedstatechange" }>>();
  for (const event of ledger.graphEvents) if (event.effect.type === "requestedstatechange") requestedBySequence.set(event.effect.sequence, event.effect);
  let lastAcceptedInput: (typeof inputs)[number] | undefined;
  for (let index = 0; index < inputs.length; index += 1) {
    const input = inputByOrdinal.get(index);
    if (input === undefined) { failures.push(`operation-missing-input:${String(index)}`); continue; }
    if (fixture !== undefined && !stateIds.has(input.target)) failures.push(`operation-target-unknown:${String(input.operationOrdinal)}`);
    const requested = requestedBySequence.get(input.inputSequence);
    if (requested === undefined || requested.to !== input.target) failures.push(`operation-request-evidence:${String(input.operationOrdinal)}`);
    else lastAcceptedInput = input;
    const headed = headedByOrdinal.get(input.operationOrdinal);
    if (headed !== undefined && (headed.eventOrdinal >= input.eventOrdinal || headed.atMicroseconds > input.atMicroseconds)) failures.push(`operation-headed-order:${String(input.operationOrdinal)}`);
    const settlement = promiseByOrdinal.get(input.operationOrdinal);
    if (settlement === undefined || settlement.eventOrdinal <= input.eventOrdinal || settlement.atMicroseconds < input.atMicroseconds) failures.push(`operation-settlement-order:${String(input.operationOrdinal)}`);
    else if ((settlement.status === "fulfilled") !== (settlement.errorName === null) || (settlement.status === "rejected" && settlement.errorName !== "AbortError")) failures.push(`operation-settlement-outcome:${String(input.operationOrdinal)}`);
  }
  for (const ordinal of inputByOrdinal.keys()) if (ordinal >= inputs.length) failures.push(`operation-order:${String(ordinal)}`);
  for (const ordinal of promiseByOrdinal.keys()) if (!inputByOrdinal.has(ordinal)) failures.push(`operation-promise-without-input:${String(ordinal)}`);
  for (const ordinal of headedByOrdinal.keys()) if (!inputByOrdinal.has(ordinal)) failures.push(`operation-headed-without-input:${String(ordinal)}`);
  if (promises.length !== inputs.length) failures.push("operation-settlement-cardinality");
  validateDomEventAgreement(domEvents, ledger.graphEvents, fixture, failures);
  const postFrame = lastAcceptedInput === undefined ? undefined : frames.find(({ raw }) => raw.callbackStartMicroseconds >= lastAcceptedInput.atMicroseconds && (raw.graphVisualState === lastAcceptedInput.target || raw.mediaState === lastAcceptedInput.target));
  if (lastAcceptedInput === undefined || postFrame === undefined) failures.push("rapid-final-convergence");
  return Object.freeze({ operationCount: inputs.length, headedOperationCount });
}

function validateDomEventAgreement(events: readonly Extract<RawRuntimeOperationEvent, { readonly kind: "dom-event" }>[], graphEvents: readonly RawRuntimeGraphEvent[], fixture: RuntimeFixtureModel | undefined, failures: string[]): void {
  const edgeById = new Map(fixture?.edges.map((edge) => [edge.id, edge]) ?? []);
  const expected = graphEvents.map(({ effect }) => graphEffectDomIdentity(effect));
  if (events.length !== expected.length) failures.push("dom-event-cardinality");
  for (let index = 0; index < events.length; index += 1) {
    const event = events[index]!;
    if (event.edge !== null) {
      const edge = edgeById.get(event.edge);
      if (fixture !== undefined && (edge === undefined || edge.from !== event.from || edge.to !== event.to)) failures.push(`dom-event-route-identity:${String(event.eventOrdinal)}`);
    }
    const identity = expected[index];
    if (identity === undefined || event.name !== identity.name || event.from !== identity.from || event.to !== identity.to || event.edge !== identity.edge || event.sequence !== identity.sequence) failures.push(`dom-event-order:${String(event.eventOrdinal)}`);
  }
}

function graphEffectDomIdentity(effect: RawRuntimeGraphEffect): Readonly<{ readonly name: Extract<RawRuntimeOperationEvent, { readonly kind: "dom-event" }>["name"]; readonly from: string; readonly to: string; readonly edge: string | null; readonly sequence: number | null }> {
  if (effect.type === "transitionstart") return Object.freeze({ name: effect.type, from: effect.from, to: effect.to, edge: effect.edgeId, sequence: effect.sequence });
  if (effect.type === "transitionend") return Object.freeze({ name: effect.type, from: effect.from, to: effect.to, edge: effect.edgeId, sequence: null });
  if (effect.type === "requestedstatechange") return Object.freeze({ name: effect.type, from: effect.from, to: effect.to, edge: null, sequence: effect.sequence });
  return Object.freeze({ name: effect.type, from: effect.from, to: effect.to, edge: null, sequence: null });
}

function validateCounters(ledger: RuntimeScenarioLedger, failures: string[]): void {
  for (const name of COUNTER_KEYS) {
    const baseline = ledger.counterBaseline[name];
    const terminal = ledger.counterTerminal[name];
    if (terminal < baseline) failures.push(`counter-regressed:${name}`);
    else if (terminal !== baseline) failures.push(`forbidden-counter-delta:${name}:${String(terminal - baseline)}`);
  }
  for (const name of ["untrackedOwnedBytes", "terminalOwnedResources"] as const) if (ledger.counterBaseline[name] !== 0 || ledger.counterTerminal[name] !== 0) failures.push(`ownership-counter-nonzero:${name}`);
}

function validateTerminalTrace(ledger: RuntimeScenarioLedger, failures: string[]): void {
  const maximumEvidenceTraceIndex = Math.max(-1, ...ledger.frames.map(({ traceIndex }) => traceIndex), ...ledger.graphEvents.map(({ traceIndex }) => traceIndex));
  const terminalUnderflows = ledger.frames.at(-1)?.cumulativeUnderflows ?? 0;
  if (ledger.terminalTrace.lastTraceIndex < maximumEvidenceTraceIndex) failures.push("terminal-trace-index-before-evidence");
  if (ledger.terminalTrace.contentTickRecords !== ledger.frames.length) failures.push("terminal-trace-content-cardinality");
  if (ledger.terminalTrace.cumulativeUnderflows !== terminalUnderflows) failures.push("terminal-trace-underflow-mismatch");
}

function validateResourceSettlement(ledger: RuntimeScenarioLedger, failures: string[]): void {
  const active = new Map<string, number>();
  const acquired = new Set<string>();
  const retired = new Set<string>();
  let priorOrdinal = -1;
  let priorTime = -1;
  let peak = 0;
  let activeBytes = 0;
  for (const event of ledger.resourceEvents) {
    if (event.eventOrdinal !== priorOrdinal + 1) failures.push(`resource-event-order:${String(event.eventOrdinal)}`);
    if (event.atMicroseconds < priorTime) failures.push(`resource-event-clock:${String(event.eventOrdinal)}`);
    priorOrdinal = event.eventOrdinal;
    priorTime = event.atMicroseconds;
    if (event.kind === "acquired") {
      if (acquired.has(event.resourceId)) failures.push(`resource-acquired-twice:${event.resourceId}`);
      acquired.add(event.resourceId);
      active.set(event.resourceId, event.resourceBytes);
      activeBytes = checkedAdd(activeBytes, event.resourceBytes, "active resource bytes");
    } else {
      const bytes = active.get(event.resourceId);
      if (bytes === undefined) failures.push(`resource-retired-without-acquire:${event.resourceId}`);
      else {
        if (bytes !== event.resourceBytes) failures.push(`resource-byte-identity:${event.resourceId}`);
        active.delete(event.resourceId);
        activeBytes = checkedSubtract(activeBytes, bytes, "active resource bytes");
      }
      retired.add(event.resourceId);
    }
    peak = Math.max(peak, active.size);
    if (event.ownedResources !== active.size) failures.push(`resource-owned-count:${String(event.eventOrdinal)}`);
    if (event.ownedBytes !== activeBytes) failures.push(`resource-owned-bytes:${String(event.eventOrdinal)}`);
  }
  if (acquired.size === 0 || peak === 0) failures.push("terminal-no-acquired-resource-evidence");
  if (active.size !== 0 || retired.size !== acquired.size) failures.push("terminal-resource-lifecycle-incomplete");
  const finalResourceEvent = ledger.resourceEvents.at(-1);
  if (finalResourceEvent === undefined || finalResourceEvent.ownedResources !== 0 || finalResourceEvent.ownedBytes !== 0) failures.push("terminal-raw-resource-event-nonzero");
  const receiptIds = new Set(ledger.cleanupReceipt.retiredResourceIds);
  if (receiptIds.size !== ledger.cleanupReceipt.retiredResourceIds.length || receiptIds.size !== retired.size || [...retired].some((id) => !receiptIds.has(id))) failures.push("terminal-cleanup-receipt-mismatch");
  for (const name of ["ownedResources", "ownedBytes", "liveWorkers", "openFrames", "pendingLoads", "activeLeases", "stalePublications"] as const) {
    const value = ledger.cleanupReceipt[name];
    if (value !== 0) failures.push(`terminal-resource:${name}:${String(value)}`);
  }
}


function emptyBoundaries(): DerivedBoundaries { return Object.freeze({ byOrdinal: new Set<number>(), loop: Object.freeze([]), routes: Object.freeze([]), inverse: Object.freeze([]), portal: Object.freeze([]) }); }
function checkedAdd(left: number, right: number, name: string): number { const result = left + right; if (!Number.isSafeInteger(result)) throw new RangeError(`${name} overflow`); return result; }
function checkedSubtract(left: number, right: number, name: string): number { const result = left - right; if (!Number.isSafeInteger(result) || result < 0) throw new RangeError(`${name} underflow`); return result; }
