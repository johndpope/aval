import type {
  RenderedMotionAutoplay,
  RenderedMotionBindings,
  RenderedMotionCrossOrigin,
  RenderedMotionFit,
  RenderedMotionMotion
} from "./public-types.js";

export const MAX_ELEMENT_URL_CODE_UNITS = 4_096;
export const MAX_INTERACTION_ID_CODE_UNITS = 256;
export const MAX_ELEMENT_SIZE_HINT = 16_384;
const IDENTIFIER_PATTERN = /^[a-z][a-z0-9._-]{0,63}$/u;
const EXTERNAL_INTEGRITY_PATTERN = /^sha256-([A-Za-z0-9+/]{43})=$/u;
const BASE64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

export interface ElementConfiguration {
  readonly src: string;
  readonly integrity: string;
  readonly crossOrigin: RenderedMotionCrossOrigin;
  readonly motion: RenderedMotionMotion;
  readonly autoplay: RenderedMotionAutoplay;
  readonly fit: RenderedMotionFit | null;
  readonly bindings: RenderedMotionBindings;
  readonly state: string | null;
  readonly interactionFor: string;
  readonly width: number | null;
  readonly height: number | null;
}

export interface ElementConfigurationFailure {
  readonly attribute: string;
  readonly code: "invalid-configuration";
}

export interface ElementConfigurationRead {
  readonly configuration: Readonly<ElementConfiguration>;
  readonly failures: readonly Readonly<ElementConfigurationFailure>[];
}

export interface ElementConfigurationChangeSet {
  readonly retrievalIdentity: boolean;
  readonly motion: boolean;
  readonly autoplay: boolean;
  readonly fit: boolean;
  readonly bindings: boolean;
  readonly state: boolean;
  readonly interactionTarget: boolean;
  readonly size: boolean;
}

export function readElementConfiguration(
  getAttribute: (name: string) => string | null
): Readonly<ElementConfigurationRead> {
  const failures: ElementConfigurationFailure[] = [];
  const read = <T>(
    name: string,
    normalize: (value: string | null) => T,
    fallback: T
  ): T => {
    try {
      return normalize(getAttribute(name));
    } catch {
      failures.push(Object.freeze({
        attribute: name,
        code: "invalid-configuration" as const
      }));
      return fallback;
    }
  };
  const configuration = Object.freeze({
    src: read("src", (value) => normalizeBoundedString(value ?? "", "src"), ""),
    integrity: read("integrity", (value) => normalizeIntegrity(value ?? ""), ""),
    crossOrigin: read("crossorigin", normalizeCrossOriginAttribute, "anonymous"),
    motion: read("motion", (value) => normalizeEnum(value ?? "auto", MOTIONS, "motion"), "auto"),
    autoplay: read(
      "autoplay",
      (value) => normalizeEnum(value ?? "visible", AUTOPLAYS, "autoplay"),
      "visible"
    ),
    fit: read("fit", normalizeFitAttribute, null),
    bindings: read(
      "bindings",
      (value) => normalizeEnum(value ?? "auto", BINDINGS, "bindings"),
      "auto"
    ),
    state: read("state", normalizeOptionalIdentifier, null),
    interactionFor: read(
      "interaction-for",
      (value) => normalizeInteractionFor(value ?? ""),
      ""
    ),
    width: read("width", normalizeOptionalSizeAttribute, null),
    height: read("height", normalizeOptionalSizeAttribute, null)
  } satisfies ElementConfiguration);
  return Object.freeze({ configuration, failures: Object.freeze(failures) });
}

export function diffElementConfiguration(
  previous: Readonly<ElementConfiguration> | null,
  next: Readonly<ElementConfiguration>
): Readonly<ElementConfigurationChangeSet> {
  if (previous === null) {
    return Object.freeze({
      retrievalIdentity: next.src !== "",
      motion: true,
      autoplay: true,
      fit: true,
      bindings: true,
      state: next.state !== null,
      interactionTarget: true,
      size: true
    });
  }
  return Object.freeze({
    retrievalIdentity:
      previous.src !== next.src ||
      previous.integrity !== next.integrity ||
      previous.crossOrigin !== next.crossOrigin,
    motion: previous.motion !== next.motion,
    autoplay: previous.autoplay !== next.autoplay,
    fit: previous.fit !== next.fit,
    bindings: previous.bindings !== next.bindings,
    state: previous.state !== next.state,
    interactionTarget: previous.interactionFor !== next.interactionFor,
    size: previous.width !== next.width || previous.height !== next.height
  });
}

export function normalizeSource(value: unknown): string {
  return normalizeBoundedString(value, "src");
}

export function normalizeIntegrity(value: unknown): string {
  if (typeof value !== "string") throw new TypeError("integrity must be a string");
  if (value === "") return "";
  if (value.length !== 51) {
    throw new TypeError("integrity must be canonical sha256 Base64 for 32 bytes");
  }
  const match = EXTERNAL_INTEGRITY_PATTERN.exec(value);
  const finalSextet = match === null
    ? -1
    : BASE64_ALPHABET.indexOf(match[1]!.at(-1)!);
  if (match === null || finalSextet < 0 || (finalSextet & 0b11) !== 0) {
    throw new TypeError("integrity must be canonical sha256 Base64 for 32 bytes");
  }
  return value;
}

export function normalizeCrossOrigin(value: unknown): RenderedMotionCrossOrigin {
  return normalizeEnum(value, CROSS_ORIGINS, "crossOrigin");
}

export function normalizeMotion(value: unknown): RenderedMotionMotion {
  return normalizeEnum(value, MOTIONS, "motion");
}

export function normalizeAutoplay(value: unknown): RenderedMotionAutoplay {
  return normalizeEnum(value, AUTOPLAYS, "autoplay");
}

export function normalizeFit(value: unknown): RenderedMotionFit | null {
  if (value === null) return null;
  return normalizeEnum(value, FITS, "fit");
}

export function normalizeBindings(value: unknown): RenderedMotionBindings {
  return normalizeEnum(value, BINDINGS, "bindings");
}

export function normalizeState(value: unknown): string | null {
  if (value === null) return null;
  if (typeof value !== "string" || !IDENTIFIER_PATTERN.test(value)) {
    throw new TypeError("state must be a valid authored identifier or null");
  }
  return value;
}

export function normalizeInteractionFor(value: unknown): string {
  if (typeof value !== "string") {
    throw new TypeError("interactionFor must be a string");
  }
  if (value.length > MAX_INTERACTION_ID_CODE_UNITS) {
    throw new RangeError("interactionFor exceeds 256 UTF-16 code units");
  }
  if (/\0|[\u0001-\u001f\u007f]/u.test(value)) {
    throw new TypeError("interactionFor contains control characters");
  }
  return value;
}

export function normalizeSize(value: unknown): number | null {
  if (value === null) return null;
  if (
    typeof value !== "number" ||
    !Number.isSafeInteger(value) ||
    value < 1 ||
    value > MAX_ELEMENT_SIZE_HINT
  ) {
    throw new RangeError("size hint must be an integer from 1 through 16384");
  }
  return value;
}

function normalizeBoundedString(value: unknown, label: string): string {
  if (typeof value !== "string") throw new TypeError(`${label} must be a string`);
  if (value.length > MAX_ELEMENT_URL_CODE_UNITS) {
    throw new RangeError(`${label} exceeds 4096 UTF-16 code units`);
  }
  return value;
}

function normalizeCrossOriginAttribute(value: string | null): RenderedMotionCrossOrigin {
  if (value === null || value === "") return "anonymous";
  return normalizeCrossOrigin(value);
}

function normalizeFitAttribute(value: string | null): RenderedMotionFit | null {
  if (value === null || value === "") return null;
  return normalizeFit(value);
}

function normalizeOptionalIdentifier(value: string | null): string | null {
  if (value === null || value === "") return null;
  return normalizeState(value);
}

function normalizeOptionalSizeAttribute(value: string | null): number | null {
  if (value === null || value === "") return null;
  if (value.length > 5 || !/^[0-9]+$/u.test(value)) {
    throw new RangeError("size attribute must be a positive integer");
  }
  return normalizeSize(Number(value));
}

function normalizeEnum<const T extends string>(
  value: unknown,
  values: ReadonlySet<T>,
  label: string
): T {
  if (
    typeof value !== "string" ||
    value.length > 64 ||
    !values.has(value as T)
  ) {
    throw new TypeError(`${label} has an unsupported value`);
  }
  return value as T;
}

const CROSS_ORIGINS: ReadonlySet<RenderedMotionCrossOrigin> = new Set([
  "anonymous",
  "use-credentials"
]);
const MOTIONS: ReadonlySet<RenderedMotionMotion> = new Set([
  "auto",
  "reduce",
  "full"
]);
const AUTOPLAYS: ReadonlySet<RenderedMotionAutoplay> = new Set([
  "visible",
  "manual"
]);
const FITS: ReadonlySet<RenderedMotionFit> = new Set([
  "contain",
  "cover",
  "fill",
  "none"
]);
const BINDINGS: ReadonlySet<RenderedMotionBindings> = new Set([
  "auto",
  "none"
]);
