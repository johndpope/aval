import {
  parseVideoCodecString,
  type CompiledManifest,
  type VideoCodec
} from "@pixel-point/aval-format";

import type { SourceSupportProbe } from "./source-support-probe.js";
import {
  selectVideoRendition,
  type VideoRenditionCandidate,
  type VideoRenditionSelectionAttempt
} from "./video-rendition-selection.js";

export interface VideoSourceDescriptor {
  /** Authored source-list position. It is diagnostic identity, never a rank. */
  readonly authoredIndex: number;
  /** Fully qualified codec value captured from the required source type. */
  readonly codec: string;
}

export interface VideoSourceSession {
  readonly catalog: Readonly<{
    readonly manifest: Readonly<CompiledManifest>;
  }>;
  dispose(): void | PromiseLike<void>;
}

export type VideoSourceAttemptOutcome =
  | "invalid-codec-hint"
  | "all-renditions-unsupported"
  | "candidate-unsupported"
  | "selected";

export interface VideoSourceSelectionAttempt {
  readonly authoredIndex: number;
  readonly outcome: VideoSourceAttemptOutcome;
  readonly renditionAttempts: readonly Readonly<VideoRenditionSelectionAttempt>[];
}

export interface AcceptedVideoSource<
  TCandidate extends VideoSourceDescriptor,
  TSession extends VideoSourceSession,
  TValue
> {
  readonly candidate: Readonly<TCandidate>;
  readonly session: TSession;
  readonly rendition: Readonly<VideoRenditionCandidate>;
  readonly value: TValue;
  readonly attempts: readonly Readonly<VideoSourceSelectionAttempt>[];
}

export interface VideoSourceAcceptanceInput<
  TCandidate extends VideoSourceDescriptor,
  TSession extends VideoSourceSession
> {
  readonly candidate: Readonly<TCandidate>;
  readonly session: TSession;
  readonly rendition: Readonly<VideoRenditionCandidate>;
  readonly signal: AbortSignal;
}

export interface VideoSourceSelectionInput<
  TCandidate extends VideoSourceDescriptor,
  TSession extends VideoSourceSession,
  TValue
> {
  readonly candidates: readonly Readonly<TCandidate>[];
  readonly signal: AbortSignal;
  open(
    candidate: Readonly<TCandidate>,
    signal: AbortSignal
  ): Promise<TSession>;
  createProbe(candidate: Readonly<TCandidate>): SourceSupportProbe;
  isResourceEligible(
    rendition: Readonly<VideoRenditionCandidate>,
    candidate: Readonly<TCandidate>,
    session: TSession
  ): boolean;
  /**
   * Perform the candidate-local configuration/decode construction. Resolving
   * transfers session ownership to the returned value. Only
   * VideoSourceCandidateUnsupportedError advances to the next source; every
   * other rejection is terminal after this candidate has been retired.
   */
  accept(
    input: Readonly<VideoSourceAcceptanceInput<TCandidate, TSession>>
  ): Promise<TValue>;
}

/** Exhaustion contains only authored positions and closed outcomes, never URLs. */
export class VideoSourceSelectionError extends Error {
  public readonly attempts: readonly Readonly<VideoSourceSelectionAttempt>[];

  public constructor(
    attempts: readonly Readonly<VideoSourceSelectionAttempt>[]
  ) {
    super("no authored AVAL source could be selected");
    this.name = "VideoSourceSelectionError";
    this.attempts = freezeAttempts(attempts);
  }
}

/** Deterministic pre-activation construction rejection safe for fallthrough. */
export class VideoSourceCandidateUnsupportedError extends Error {
  public constructor() {
    super("selected source candidate is deterministically unsupported");
    this.name = "VideoSourceCandidateUnsupportedError";
  }
}

/**
 * Sequential, generation-scoped source selection. No work for a later source
 * starts until the previous source's probe and metadata session have retired.
 */
export async function selectVideoSource<
  TCandidate extends VideoSourceDescriptor,
  TSession extends VideoSourceSession,
  TValue
>(
  input: Readonly<VideoSourceSelectionInput<TCandidate, TSession, TValue>>
): Promise<Readonly<AcceptedVideoSource<TCandidate, TSession, TValue>>> {
  validateInput(input);
  const candidates = detachCandidates(input.candidates);
  const attempts: VideoSourceSelectionAttempt[] = [];

  for (const candidate of candidates) {
    throwIfAborted(input.signal);
    const family = codecFamily(candidate.codec);
    if (family === null) {
      attempts.push(createAttempt(candidate, "invalid-codec-hint"));
      continue;
    }

    let session: TSession | null = null;
    let probe: SourceSupportProbe | null = null;
    let renditionAttempts: readonly Readonly<VideoRenditionSelectionAttempt>[] =
      Object.freeze([]);
    let outcome: VideoSourceAttemptOutcome | null = null;
    try {
      session = await input.open(candidate, input.signal);
      throwIfAborted(input.signal);
      validateSession(session);
      const manifest = session.catalog.manifest;
      if (manifest.codec !== family) {
        throw new TypeError(
          "opened AVAL asset codec disagrees with its source type"
        );
      }

      probe = input.createProbe(candidate);
      validateProbe(probe);
      const selection = await selectVideoRendition({
        manifest,
        isResourceEligible: (rendition) => input.isResourceEligible(
          rendition,
          candidate,
          session as TSession
        ),
        probeDecoderConfig: (config) => probe!.probe(config, {
          signal: input.signal
        })
      });
      renditionAttempts = selection.attempts;
      throwIfAborted(input.signal);
      if (selection.outcome === "all-unsupported") {
        outcome = "all-renditions-unsupported";
        throw new CandidateRejected();
      }

      await disposeProbe(probe);
      probe = null;
      throwIfAborted(input.signal);
      let value: TValue;
      try {
        value = await input.accept(Object.freeze({
          candidate,
          session,
          rendition: selection.selected,
          signal: input.signal
        }));
      } catch (error) {
        if (!(error instanceof VideoSourceCandidateUnsupportedError)) {
          throw error;
        }
        outcome = "candidate-unsupported";
        throw new CandidateRejected();
      }
      throwIfAborted(input.signal);
      attempts.push(createAttempt(candidate, "selected", renditionAttempts));
      return Object.freeze({
        candidate,
        session,
        rendition: selection.selected,
        value,
        attempts: freezeAttempts(attempts)
      });
    } catch (error) {
      const aborted = input.signal.aborted;
      const cleanupError = await retireRejected(session, probe);
      if (aborted) throw abortReason(input.signal);
      if (cleanupError !== null) {
        throw new AggregateError(
          [error, cleanupError],
          "rejected AVAL source cleanup failed"
        );
      }
      if (!(error instanceof CandidateRejected) || outcome === null) {
        throw error;
      }
      attempts.push(createAttempt(candidate, outcome, renditionAttempts));
    }
  }

  throw new VideoSourceSelectionError(attempts);
}

class CandidateRejected extends Error {}

function validateInput(input: unknown): asserts input is Readonly<
  VideoSourceSelectionInput<VideoSourceDescriptor, VideoSourceSession, unknown>
> {
  if (input === null || typeof input !== "object" || Array.isArray(input)) {
    throw new TypeError("video source selection input must be an object");
  }
  const value = input as Partial<
    VideoSourceSelectionInput<VideoSourceDescriptor, VideoSourceSession, unknown>
  >;
  if (!Array.isArray(value.candidates) || value.candidates.length === 0) {
    throw new TypeError("video source selection requires authored candidates");
  }
  if (!(value.signal instanceof AbortSignal)) {
    throw new TypeError("video source selection requires an AbortSignal");
  }
  for (const callback of [
    value.open,
    value.createProbe,
    value.isResourceEligible,
    value.accept
  ]) {
    if (typeof callback !== "function") {
      throw new TypeError("video source selection callback is unavailable");
    }
  }
}

function detachCandidates<TCandidate extends VideoSourceDescriptor>(
  candidates: readonly Readonly<TCandidate>[]
): readonly Readonly<TCandidate>[] {
  const result: Readonly<TCandidate>[] = [];
  const seen = new Set<number>();
  for (let index = 0; index < candidates.length; index += 1) {
    if (!Object.prototype.hasOwnProperty.call(candidates, String(index))) {
      throw new TypeError("video source candidates must be dense");
    }
    const candidate = candidates[index];
    if (
      candidate === null ||
      typeof candidate !== "object" ||
      !Number.isSafeInteger(candidate.authoredIndex) ||
      candidate.authoredIndex < 0 ||
      seen.has(candidate.authoredIndex) ||
      typeof candidate.codec !== "string"
    ) {
      throw new TypeError("video source candidate is invalid");
    }
    seen.add(candidate.authoredIndex);
    // Detach only selection authority. Unknown host fields remain on the frozen
    // descriptor without being read by this module.
    result.push(Object.freeze({ ...candidate }));
  }
  return Object.freeze(result);
}

function codecFamily(codec: string): VideoCodec | null {
  try {
    return parseVideoCodecString(codec)?.family ?? null;
  } catch {
    return null;
  }
}

function validateSession(value: VideoSourceSession): void {
  if (
    value === null ||
    typeof value !== "object" ||
    typeof value.dispose !== "function" ||
    value.catalog === null ||
    typeof value.catalog !== "object" ||
    value.catalog.manifest === null ||
    typeof value.catalog.manifest !== "object"
  ) {
    throw new TypeError("opened video source session is malformed");
  }
}

function validateProbe(value: SourceSupportProbe): void {
  if (
    value === null ||
    typeof value !== "object" ||
    typeof value.probe !== "function" ||
    typeof value.dispose !== "function"
  ) {
    throw new TypeError("video source support probe is malformed");
  }
}

function createAttempt(
  candidate: Readonly<VideoSourceDescriptor>,
  outcome: VideoSourceAttemptOutcome,
  renditionAttempts: readonly Readonly<VideoRenditionSelectionAttempt>[] =
    Object.freeze([])
): Readonly<VideoSourceSelectionAttempt> {
  return Object.freeze({
    authoredIndex: candidate.authoredIndex,
    outcome,
    renditionAttempts: Object.freeze(renditionAttempts.map((attempt) =>
      Object.freeze({ ...attempt })
    ))
  });
}

function freezeAttempts(
  attempts: readonly Readonly<VideoSourceSelectionAttempt>[]
): readonly Readonly<VideoSourceSelectionAttempt>[] {
  return Object.freeze(attempts.map((attempt) => Object.freeze({
    authoredIndex: attempt.authoredIndex,
    outcome: attempt.outcome,
    renditionAttempts: Object.freeze(attempt.renditionAttempts.map((rendition) =>
      Object.freeze({ ...rendition })
    ))
  })));
}

async function retireRejected(
  session: VideoSourceSession | null,
  probe: SourceSupportProbe | null
): Promise<unknown | null> {
  const failures: unknown[] = [];
  if (probe !== null) {
    try { await probe.dispose(); } catch (error) { failures.push(error); }
  }
  if (session !== null) {
    try { await session.dispose(); } catch (error) { failures.push(error); }
  }
  return failures.length === 0
    ? null
    : failures.length === 1
      ? failures[0]
      : new AggregateError(failures, "source cleanup failed");
}

async function disposeProbe(probe: SourceSupportProbe): Promise<void> {
  await probe.dispose();
}

function throwIfAborted(signal: AbortSignal): void {
  if (signal.aborted) throw abortReason(signal);
}

function abortReason(signal: AbortSignal): unknown {
  return signal.reason ?? new DOMException("operation aborted", "AbortError");
}
