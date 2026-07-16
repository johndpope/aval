import type { DecoderWorkerConfigureOptions } from "../decoder-worker/client.js";
import { DECODER_WORKER_HARD_LIMITS } from "../decoder-worker/protocol.js";
import type { IntegratedCandidateAttemptContext } from "./integrated-player-contracts.js";
import type { VideoCandidateWorkerSetup } from "./video-candidate-model.js";
import { RESOURCE_DECODE_SURFACE_COUNT } from "./resource-plan.js";

/** Derive the only accepted worker configuration from codec-adapter facts. */
export function createVideoCandidateWorkerSetup(
  context: Readonly<IntegratedCandidateAttemptContext>
): Readonly<VideoCandidateWorkerSetup> {
  const rendition = context.candidate.rendition;
  const geometry = context.candidate.geometry;
  const inspection = context.inspection;
  const storage = geometry.decodedStorageRect;
  const decoder = inspection.decoderConfig;
  if (
    inspection.family !== context.catalog.manifest.codec ||
    inspection.bitstream !== context.catalog.manifest.bitstream ||
    inspection.bitDepth !== rendition.bitDepth ||
    decoder.codec !== rendition.codec ||
    decoder.codedWidth !== rendition.codedWidth ||
    decoder.codedHeight !== rendition.codedHeight ||
    decoder.displayAspectWidth !== storage[2] ||
    decoder.displayAspectHeight !== storage[3] ||
    decoder.colorSpace?.fullRange !== false ||
    decoder.colorSpace?.primaries !== "bt709" ||
    decoder.colorSpace?.transfer !== "bt709" ||
    decoder.colorSpace?.matrix !== "bt709" ||
    Object.hasOwn(decoder, "description")
  ) {
    throw new RangeError(
      "video candidate inspection does not match its exact decoder profile"
    );
  }

  if (
    geometry.codedRgbaBytes >
      Math.floor(Number.MAX_SAFE_INTEGER / RESOURCE_DECODE_SURFACE_COUNT)
  ) {
    throw new RangeError("video candidate decoded byte limit is unsafe");
  }
  const maxDecodedBytes =
    geometry.codedRgbaBytes * RESOURCE_DECODE_SURFACE_COUNT;
  const limits = Object.freeze({
    maxDecodeQueueSize: DECODER_WORKER_HARD_LIMITS.maxDecodeQueueSize,
    maxPendingSamples: DECODER_WORKER_HARD_LIMITS.maxPendingSamples,
    maxOutstandingFrames: RESOURCE_DECODE_SURFACE_COUNT,
    maxDecodedBytes
  });
  const configure: Readonly<DecoderWorkerConfigureOptions> = Object.freeze({
    config: Object.freeze({
      ...decoder,
      hardwareAcceleration: "no-preference" as const,
      optimizeForLatency: true as const
    }),
    videoProfile: Object.freeze({
      codecFamily: inspection.family,
      bitDepth: inspection.bitDepth,
      codedWidth: rendition.codedWidth,
      codedHeight: rendition.codedHeight,
      frameRate: Object.freeze({
        numerator: context.catalog.manifest.frameRate.numerator,
        denominator: context.catalog.manifest.frameRate.denominator
      }),
      requireBt709LimitedRange: true as const
    }),
    expectedOutput: Object.freeze({
      codedWidth: rendition.codedWidth,
      codedHeight: rendition.codedHeight,
      displayWidth: storage[2],
      displayHeight: storage[3],
      visibleRect: Object.freeze({
        x: storage[0],
        y: storage[1],
        width: storage[2],
        height: storage[3]
      }),
      colorSpace: Object.freeze({
        fullRange: false,
        matrix: "bt709" as const,
        primaries: "bt709" as const,
        transfer: "bt709" as const
      })
    }),
    limits
  });
  return Object.freeze({ configure, limits });
}
