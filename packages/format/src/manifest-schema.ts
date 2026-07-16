import { resolveFormatBudgets } from "./constants.js";
import { FormatError } from "./errors.js";
import {
  cloneBindings,
  cloneEdges,
  cloneReadiness,
  cloneStates
} from "./manifest-graph-schema.js";
import { cloneDeclaredLimits } from "./manifest-limits-schema.js";
import {
  validateBlobCount,
  validateManifestRelations,
  validateRawBlobCount
} from "./manifest-relations.js";
import {
  cloneCanvas,
  cloneFrameRate,
  cloneRenditions
} from "./manifest-rendition-schema.js";
import {
  exactKeys,
  generatorString,
  identifier,
  literal,
  oneOf,
  record,
  invalid
} from "./manifest-validation.js";
import { cloneUnits } from "./manifest-unit-schema.js";
import type {
  CompiledManifest,
  FormatOptions,
  VideoBitstream,
  VideoCodec
} from "./model.js";

const TOP_LEVEL_KEYS = [
  "formatVersion",
  "generator",
  "codec",
  "bitstream",
  "layout",
  "canvas",
  "frameRate",
  "renditions",
  "units",
  "initialState",
  "states",
  "edges",
  "bindings",
  "readiness",
  "limits"
] as const;

const BITSTREAM_BY_CODEC: Readonly<Record<VideoCodec, VideoBitstream>> =
  Object.freeze({
    h264: "annex-b",
    h265: "annex-b",
    vp9: "frame",
    av1: "low-overhead"
  });

/** Validate, detach, and recursively freeze the sole production manifest. */
export function validateCompiledManifest(
  value: unknown,
  options?: FormatOptions
): CompiledManifest {
  try {
    const budgets = resolveFormatBudgets(options);
    const input = record(value, "manifest");
    exactKeys(input, TOP_LEVEL_KEYS, "manifest");
    literal(input.formatVersion, "1.0", "formatVersion");
    const generator = generatorString(input.generator, "generator");
    const codec = oneOf(input.codec, ["h264", "h265", "vp9", "av1"], "codec");
    const bitstream = oneOf(
      input.bitstream,
      ["annex-b", "frame", "low-overhead"],
      "bitstream"
    );
    if (bitstream !== BITSTREAM_BY_CODEC[codec]) {
      invalid("bitstream", `must be ${BITSTREAM_BY_CODEC[codec]} for ${codec}`);
    }
    const layout = oneOf(input.layout, ["opaque", "packed-alpha"], "layout");
    const canvas = cloneCanvas(input.canvas, "canvas");
    const frameRate = cloneFrameRate(input.frameRate, "frameRate");
    const renditions = cloneRenditions(
      input.renditions,
      canvas,
      codec,
      layout,
      budgets,
      "renditions"
    );
    validateRawBlobCount(input.units, renditions.length, budgets);
    const units = cloneUnits(input.units, renditions, budgets, "units");
    const initialState = identifier(input.initialState, "initialState");
    const states = cloneStates(input.states, budgets, "states");
    const edges = cloneEdges(input.edges, budgets, "edges");
    const bindings = cloneBindings(input.bindings, budgets, "bindings");
    const readiness = cloneReadiness(input.readiness, budgets, "readiness");
    const limits = cloneDeclaredLimits(
      input.limits,
      renditions,
      budgets,
      "limits"
    );

    validateBlobCount(units, renditions, budgets);
    validateManifestRelations({
      initialState,
      renditions,
      units,
      states,
      edges,
      bindings,
      readiness
    });

    return Object.freeze({
      formatVersion: "1.0",
      generator,
      codec,
      bitstream,
      layout,
      canvas,
      frameRate,
      renditions,
      units,
      initialState,
      states,
      edges,
      bindings,
      readiness,
      limits
    });
  } catch (error) {
    if (error instanceof FormatError) throw error;
    throw new FormatError("MANIFEST_INVALID", "manifest validation failed");
  }
}
