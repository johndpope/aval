import { createCanonicalChunkPlan } from "./chunk-plan.js";
import { FormatError } from "./errors.js";
import {
  MAX_RUNWAY_FRAMES,
  MIN_RUNWAY_FRAMES
} from "./manifest-constraints.js";
import {
  boundedArray,
  compareEndpoint,
  digest,
  exactKeys,
  identifier,
  integerInRange,
  invalid,
  literal,
  nonNegativeInteger,
  oneOf,
  positiveInteger,
  quote,
  record,
  requireIdOrder,
  requireNumberOrder,
  tuple
} from "./manifest-validation.js";
import type {
  FormatBudgets,
  Port,
  ProductionRendition,
  ResidencyEndpoint,
  Unit,
  UnitChunkSpan
} from "./model.js";

export function cloneUnits(
  value: unknown,
  renditions: readonly ProductionRendition[],
  budgets: FormatBudgets,
  path: string
): readonly Unit[] {
  const inputs = boundedArray(value, path, 1, budgets.maxUnits);
  const units = inputs.map((entry, index) =>
    cloneUnit(entry, renditions, budgets, `${path}[${String(index)}]`)
  );
  requireIdOrder(units, path);
  try {
    createCanonicalChunkPlan(
      renditions,
      units,
      budgets.maxChunkRecords,
      budgets.maxTotalUnitFrames
    );
  } catch (error) {
    if (error instanceof FormatError) {
      if (error.code === "BUDGET_EXCEEDED" || error.code === "INTEGER_UNSAFE") {
        throw error;
      }
      invalid(error.path ?? path, error.message);
    }
    invalid(path, "canonical chunk plan could not be derived");
  }
  return Object.freeze(units);
}

function cloneUnit(
  value: unknown,
  renditions: readonly ProductionRendition[],
  budgets: FormatBudgets,
  path: string
): Unit {
  const input = record(value, path);
  const kind = input.kind;
  if (kind === "body") {
    exactKeys(input, ["id", "kind", "playback", "frameCount", "ports", "chunks"], path);
    const id = identifier(input.id, `${path}.id`);
    const playback = oneOf(input.playback, ["loop", "finite"], `${path}.playback`);
    const frameCount = positiveInteger(input.frameCount, `${path}.frameCount`);
    if (playback === "loop" && frameCount < 2) {
      invalid(`${path}.frameCount`, "looping bodies require at least two frames");
    }
    const ports = clonePorts(input.ports, frameCount, budgets.maxPortsPerBody, `${path}.ports`);
    const chunks = cloneChunkSpans(input.chunks, renditions, frameCount, `${path}.chunks`);
    return Object.freeze({ id, kind, playback, frameCount, ports, chunks });
  }
  if (kind === "bridge" || kind === "one-shot") {
    exactKeys(input, ["id", "kind", "frameCount", "chunks"], path);
    const id = identifier(input.id, `${path}.id`);
    const frameCount = positiveInteger(input.frameCount, `${path}.frameCount`);
    const chunks = cloneChunkSpans(input.chunks, renditions, frameCount, `${path}.chunks`);
    return Object.freeze({ id, kind, frameCount, chunks });
  }
  if (kind === "reversible") {
    exactKeys(input, ["id", "kind", "frameCount", "residency", "chunks"], path);
    const id = identifier(input.id, `${path}.id`);
    const frameCount = positiveInteger(
      input.frameCount,
      `${path}.frameCount`,
      budgets.maxReversibleFrames
    );
    const residencyInput = record(input.residency, `${path}.residency`);
    exactKeys(residencyInput, ["endpoints"], `${path}.residency`);
    const endpointsInput = tuple(residencyInput.endpoints, 2, `${path}.residency.endpoints`);
    const first = cloneResidencyEndpoint(endpointsInput[0], `${path}.residency.endpoints[0]`);
    const second = cloneResidencyEndpoint(endpointsInput[1], `${path}.residency.endpoints[1]`);
    if (compareEndpoint(first, second) >= 0) {
      invalid(`${path}.residency.endpoints`, "must be distinct and sorted by state then port");
    }
    const residency = Object.freeze({
      endpoints: Object.freeze([first, second]) as readonly [ResidencyEndpoint, ResidencyEndpoint]
    });
    const chunks = cloneChunkSpans(input.chunks, renditions, frameCount, `${path}.chunks`);
    return Object.freeze({ id, kind, frameCount, residency, chunks });
  }
  invalid(`${path}.kind`, "must be body, bridge, reversible, or one-shot");
}

function cloneChunkSpans(
  value: unknown,
  renditions: readonly ProductionRendition[],
  unitFrameCount: number,
  path: string
): readonly UnitChunkSpan[] {
  const inputs = tuple(value, renditions.length, path);
  const spans = inputs.map((entry, renditionIndex) => {
    const spanPath = `${path}[${String(renditionIndex)}]`;
    const input = record(entry, spanPath);
    exactKeys(
      input,
      ["rendition", "chunkStart", "chunkCount", "frameCount", "sha256"],
      spanPath
    );
    const rendition = identifier(input.rendition, `${spanPath}.rendition`);
    const expected = renditions[renditionIndex]?.id;
    if (rendition !== expected) {
      invalid(`${spanPath}.rendition`, `must be ${quote(expected ?? "")}`);
    }
    const chunkStart = nonNegativeInteger(input.chunkStart, `${spanPath}.chunkStart`);
    const chunkCount = positiveInteger(input.chunkCount, `${spanPath}.chunkCount`);
    const frameCount = positiveInteger(input.frameCount, `${spanPath}.frameCount`);
    if (frameCount !== unitFrameCount) {
      invalid(`${spanPath}.frameCount`, "must equal the unit frameCount");
    }
    return Object.freeze({
      rendition,
      chunkStart,
      chunkCount,
      frameCount,
      sha256: digest(input.sha256, `${spanPath}.sha256`)
    });
  });
  return Object.freeze(spans);
}

function clonePorts(
  value: unknown,
  frameCount: number,
  maximum: number,
  path: string
): readonly Port[] {
  const inputs = boundedArray(value, path, 0, maximum);
  const ports = inputs.map((entry, index) => {
    const portPath = `${path}[${String(index)}]`;
    const input = record(entry, portPath);
    exactKeys(input, ["id", "entryFrame", "portalFrames"], portPath);
    const id = identifier(input.id, `${portPath}.id`);
    literal(input.entryFrame, 0, `${portPath}.entryFrame`);
    const frameInputs = boundedArray(input.portalFrames, `${portPath}.portalFrames`, 1, frameCount);
    const portalFrames = frameInputs.map((frame, frameIndex) =>
      integerInRange(
        frame,
        `${portPath}.portalFrames[${String(frameIndex)}]`,
        0,
        frameCount - 1
      )
    );
    requireNumberOrder(portalFrames, `${portPath}.portalFrames`);
    return Object.freeze({ id, entryFrame: 0 as const, portalFrames: Object.freeze(portalFrames) });
  });
  requireIdOrder(ports, path);
  return Object.freeze(ports);
}

function cloneResidencyEndpoint(value: unknown, path: string): ResidencyEndpoint {
  const input = record(value, path);
  exactKeys(input, ["state", "port", "frames"], path);
  return Object.freeze({
    state: identifier(input.state, `${path}.state`),
    port: identifier(input.port, `${path}.port`),
    frames: integerInRange(input.frames, `${path}.frames`, MIN_RUNWAY_FRAMES, MAX_RUNWAY_FRAMES)
  });
}
