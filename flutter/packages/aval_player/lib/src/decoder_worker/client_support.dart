/// Decoder-worker client contracts referenced by the path scheduler.
///
/// **Partial port** of `packages/player-web/src/decoder-worker/client-support.ts`.
/// Only [DecoderWorkerWaitOptions] and [ManagedDecoderWorkerFrame] — the two
/// shapes the path-scheduler family references — are ported here as frozen
/// types. The client runtime, its error classes, and the configure/wait
/// validation helpers are a later phase's responsibility and will extend this
/// file.
///
/// `AbortSignal` and `VideoFrame` map onto the platform seams in
/// `../platform.dart`. `outputCallbackMicroseconds?` becomes a nullable `int`.
library;

import '../platform.dart';

/// Options for awaiting decoded frames.
class DecoderWorkerWaitOptions {
  const DecoderWorkerWaitOptions({this.signal, this.timeoutMs});

  final AbortSignal? signal;
  final int? timeoutMs;
}

/// Base for the decoder-worker error taxonomy, carrying the JS `Error.name`
/// the path-scheduler's failure classification reads
/// (`path-scheduler.ts:794`). Partial: only [DecoderWorkerWatchdogError] — the
/// one the scheduler and its tests observe — is ported from
/// `decoder-worker/client-support.ts:45-83`; the remaining error classes remain
/// a later phase's responsibility.
abstract class DecoderWorkerError implements Exception {
  DecoderWorkerError(this.message);

  final String message;

  /// Mirrors JS `Error.name`.
  String get name;

  @override
  String toString() => '$name: $message';
}

/// Raised when the decode client's frame watchdog fires
/// (`client-support.ts:78`).
class DecoderWorkerWatchdogError extends DecoderWorkerError {
  DecoderWorkerWatchdogError(super.message);

  @override
  String get name => 'DecoderWorkerWatchdogError';
}

/// A decoded frame the client hands to the presentation ring.
///
/// The concrete implementation (the TS `ManagedDecoderWorkerFrameImpl`) is
/// owned by the decode client; the scheduler only consumes this interface.
abstract interface class ManagedDecoderWorkerFrame {
  VideoFrame get frame;
  int get frameId;
  int get generation;
  int get ordinal;
  String get unitId;
  int get unitInstance;
  int get unitFrame;
  int get timestamp;
  int get duration;
  int? get outputCallbackMicroseconds;
  int get decodedBytes;
  bool get closed;
  void close();
}
