/// Decoder-worker protocol data types referenced by the path scheduler.
///
/// **Partial port** of `packages/player-web/src/decoder-worker/protocol.ts`.
/// Only the three data shapes the path-scheduler family needs —
/// [DecoderWorkerLimits], [DecoderWorkerSample], [DecoderWorkerMetrics] — plus
/// the [EncodedVideoChunkType] discriminant are ported here as frozen types.
/// The command/event message unions, the message-port interfaces, and the
/// worker runtime are a later phase's responsibility and will extend this file.
///
/// The TypeScript `ArrayBuffer` (transferred access-unit bytes) becomes a Dart
/// `ByteBuffer`; `EncodedVideoChunkType` (the browser `"key" | "delta"` union)
/// becomes an enum with the wire values preserved.
library;

import 'dart:typed_data';

/// Access-unit chunk classification (`EncodedVideoChunkType`).
enum EncodedVideoChunkType {
  key('key'),
  delta('delta');

  const EncodedVideoChunkType(this.wireValue);

  final String wireValue;
}

/// Backpressure/queue-depth limits configured for the decoder.
class DecoderWorkerLimits {
  const DecoderWorkerLimits({
    required this.maxDecodeQueueSize,
    required this.maxPendingSamples,
    required this.maxOutstandingFrames,
    required this.maxDecodedBytes,
  });

  /// Maximum native decoder input queue depth.
  final int maxDecodeQueueSize;

  /// Maximum accepted samples waiting to enter WebCodecs.
  final int maxPendingSamples;

  /// Combined submitted-output and transferred-frame credit ceiling.
  final int maxOutstandingFrames;

  /// Logical RGBA bytes leased to the main thread at once.
  final int maxDecodedBytes;
}

/// One owned access unit.
///
/// Posting a submit command transfers [data]; callers must not retain or mutate
/// that buffer afterward.
class DecoderWorkerSample {
  const DecoderWorkerSample({
    required this.ordinal,
    required this.unitId,
    required this.unitInstance,
    required this.unitFrame,
    required this.unitFrameCount,
    required this.type,
    required this.timestamp,
    required this.duration,
    required this.data,
  });

  final int ordinal;
  final String unitId;
  final int unitInstance;
  final int unitFrame;
  final int unitFrameCount;
  final EncodedVideoChunkType type;
  final int timestamp;
  final int duration;
  final ByteBuffer data;
}

/// Observable decoder counters.
class DecoderWorkerMetrics {
  const DecoderWorkerMetrics({
    required this.configureCalls,
    required this.resetCalls,
    required this.flushCalls,
    required this.boundaryFlushCalls,
    required this.acceptedSamples,
    required this.submittedChunks,
    required this.outputFrames,
    required this.deliveredFrames,
    required this.releasedFrames,
    required this.staleFrames,
    required this.closedFrames,
    required this.pendingSamples,
    required this.submittedFrames,
    required this.leasedFrames,
    required this.leasedDecodedBytes,
    required this.decodeQueueSize,
    required this.activeGeneration,
    required this.nextSubmissionOrdinal,
    required this.nextOutputOrdinal,
    required this.errors,
    required this.disposed,
  });

  final int configureCalls;

  /// Always `0`.
  final int resetCalls;

  /// Always `0`.
  final int flushCalls;

  /// Always `0`.
  final int boundaryFlushCalls;
  final int acceptedSamples;
  final int submittedChunks;
  final int outputFrames;
  final int deliveredFrames;
  final int releasedFrames;
  final int staleFrames;
  final int closedFrames;
  final int pendingSamples;
  final int submittedFrames;
  final int leasedFrames;
  final int leasedDecodedBytes;
  final int decodeQueueSize;
  final int? activeGeneration;
  final int nextSubmissionOrdinal;
  final int nextOutputOrdinal;
  final int errors;
  final bool disposed;
}
