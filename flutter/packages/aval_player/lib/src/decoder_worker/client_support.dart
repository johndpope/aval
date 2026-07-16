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
