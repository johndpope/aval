/// Shared types for the path-scheduler family.
///
/// Direct port of `packages/player-web/src/runtime/path-scheduler-model.ts`.
/// These are the frozen contracts the follow-on `path-scheduler.ts` port binds
/// against. TypeScript behavioral interfaces (`PathSchedulerWorkerAdapter`,
/// `PathSchedulerClock`) become `abstract interface class`es; data-shape
/// interfaces become immutable classes; discriminated unions
/// (`PathSchedulerTakeResult`) become sealed-class hierarchies carrying the
/// same `kind` wire string. `Promise<void>` becomes `Future<void>`; `bigint`
/// becomes `BigInt`; `number` becomes `int`.
///
/// Cross-module type references resolve to: `aval_graph` (graph definitions);
/// the partial ports in `decoder_worker/protocol.dart`,
/// `decoder_worker/client_support.dart`, `model.dart`, `worker_samples.dart`;
/// `decode_timeline.dart` and `submission_horizon.dart` from this task; and the
/// `platform.dart` seams (`AbortSignal`).
library;

import 'package:aval_graph/aval_graph.dart';

import 'decode_timeline.dart';
import 'decoder_worker/client_support.dart';
import 'decoder_worker/protocol.dart';
import 'model.dart';
import 'platform.dart';
import 'submission_horizon.dart';
import 'worker_samples.dart';

/// Lifecycle status of the path scheduler.
enum PathSchedulerStatus {
  idle('idle'),
  active('active'),
  error('error'),
  disposed('disposed');

  const PathSchedulerStatus(this.wireValue);

  final String wireValue;
}

/// Which segment of a path a scheduled frame belongs to.
enum PathSchedulerFramePurpose {
  source('source'),
  bridge('bridge'),
  target('target');

  const PathSchedulerFramePurpose(this.wireValue);

  final String wireValue;
}

/// Decoder-worker surface required by the active-path scheduler.
abstract interface class PathSchedulerWorkerAdapter {
  int? get activeGeneration;
  int get queuedFrames;
  int get openFrames;
  Future<void> activateGeneration(int generation);
  Future<void> submit(int generation, List<DecoderWorkerSample> samples);
  Future<void> abortGeneration(int generation);
  ManagedDecoderWorkerFrame? takeFrame();
  Future<void> waitForFrames([int? minimum, DecoderWorkerWaitOptions? options]);
  Future<DecoderWorkerMetrics> snapshotMetrics();
}

/// Monotonic clock the scheduler reads.
abstract interface class PathSchedulerClock {
  int now();
}

/// Construction options for the path scheduler.
class PathSchedulerOptions {
  const PathSchedulerOptions({
    required this.timeline,
    required this.samples,
    required this.worker,
    required this.rendition,
    required this.ringCapacity,
    required this.limits,
    required this.clock,
    this.maxBatchSamples,
  });

  final DecodeTimeline timeline;
  final WorkerSampleFactory samples;
  final PathSchedulerWorkerAdapter worker;
  final String rendition;
  final int ringCapacity;
  final DecoderWorkerLimits limits;
  final PathSchedulerClock clock;
  final int? maxBatchSamples;
}

/// Input to begin a scheduled body.
class StartScheduledBodyInput {
  const StartScheduledBodyInput({
    required this.state,
    required this.body,
    required this.outgoingStarts,
    required this.path,
    this.firstPresentationOrdinal,
  });

  final String state;
  final GraphBodyDefinition body;
  final List<GraphStartPolicy> outgoingStarts;
  final String path;
  final BigInt? firstPresentationOrdinal;
}

/// Input to prepare a scheduled route.
class PrepareScheduledRouteInput {
  const PrepareScheduledRouteInput({
    required this.edge,
    required this.targetState,
    required this.targetBody,
    this.replacementPath,
    this.signal,
    this.preserveReservedSource,
  });

  final GraphEdgeDefinition edge;
  final String targetState;
  final GraphBodyDefinition targetBody;
  final String? replacementPath;
  final AbortSignal? signal;

  /// Keeps an uploaded source reservation across pending-route replacement.
  final bool? preserveReservedSource;
}

/// One resident frame supplied to a resident runway.
class PathSchedulerResidentFrame {
  const PathSchedulerResidentFrame({
    required this.frame,
    required this.unitInstance,
    required this.decodeOrdinal,
    required this.timestamp,
  });

  final RuntimeFrameKey frame;
  final int unitInstance;
  final int decodeOrdinal;
  final int timestamp;
}

/// Input to begin a resident runway.
class StartResidentRunwayInput {
  const StartResidentRunwayInput({
    required this.edgeId,
    required this.targetState,
    required this.targetBody,
    required this.frames,
    required this.path,
    this.signal,
    this.firstPresentationOrdinal,
  });

  final String edgeId;
  final String targetState;
  final GraphBodyDefinition targetBody;
  final List<PathSchedulerResidentFrame> frames;
  final String path;
  final AbortSignal? signal;
  final BigInt? firstPresentationOrdinal;
}

/// Scheduler-issued, identity-stable reservation for one resident runway.
class PathSchedulerResidentRunwayTransaction {
  const PathSchedulerResidentRunwayTransaction({
    required this.generation,
    required this.path,
    required this.edgeId,
    required this.targetState,
    required this.media,
  });

  final int generation;
  final String path;
  final String edgeId;
  final String targetState;
  final List<RuntimeMediaPresentationFrame> media;
}

/// Options for committing a resident runway.
class CommitResidentRunwayOptions {
  const CommitResidentRunwayOptions({this.alreadyPresented});

  /// Browser draw-barrier commits frame zero; compatibility activation uses 0.
  /// Restricted to `0 | 1` in the TypeScript source.
  final int? alreadyPresented;
}

/// One-shot lazy worker activation; invoke only inside the media lane.
typedef PathSchedulerWorkerActivation = Future<void> Function();

/// Options for one pump step.
class PathSchedulerPumpOptions {
  const PathSchedulerPumpOptions({
    this.targetRingFrames,
    this.signal,
    this.timeoutMs,
  });

  final int? targetRingFrames;
  final AbortSignal? signal;
  final int? timeoutMs;
}

/// Report from one pump step.
class PathSchedulerPumpReport {
  const PathSchedulerPumpReport({
    required this.submittedFrames,
    required this.decodedFrames,
    required this.discardedFrames,
    required this.staleFrames,
    required this.waits,
    required this.ringSize,
    required this.expectedOutputs,
  });

  final int submittedFrames;
  final int decodedFrames;
  final int discardedFrames;
  final int staleFrames;
  final int waits;
  final int ringSize;
  final int expectedOutputs;
}

/// Result of taking the next presentation from the scheduler.
sealed class PathSchedulerTakeResult {
  const PathSchedulerTakeResult();

  String get kind;
}

class PathSchedulerTakeFrame extends PathSchedulerTakeResult {
  const PathSchedulerTakeFrame({
    required this.purpose,
    required this.media,
    required this.frame,
  });

  final PathSchedulerFramePurpose purpose;
  final RuntimeMediaPresentationFrame media;
  final ManagedDecoderWorkerFrame frame;

  @override
  String get kind => 'frame';
}

class PathSchedulerTakeResident extends PathSchedulerTakeResult {
  const PathSchedulerTakeResident({required this.media});

  final RuntimeMediaPresentationFrame media;

  @override
  String get kind => 'resident';
}

class PathSchedulerTakeRouteBlocked extends PathSchedulerTakeResult {
  const PathSchedulerTakeRouteBlocked();

  @override
  String get kind => 'route-blocked';
}

class PathSchedulerTakeUnderflow extends PathSchedulerTakeResult {
  const PathSchedulerTakeUnderflow();

  @override
  String get kind => 'underflow';
}

class PathSchedulerTakeHeld extends PathSchedulerTakeResult {
  const PathSchedulerTakeHeld();

  @override
  String get kind => 'held';
}

/// Bounded operation-trace operation kinds.
enum PathSchedulerTraceOperation {
  activate('activate'),
  submit('submit'),
  output('output'),
  discardOutput('discard-output'),
  staleOutput('stale-output'),
  present('present'),
  residentPresent('resident-present'),
  routeSelect('route-select'),
  routeCommit('route-commit'),
  generationRetire('generation-retire'),
  underflow('underflow'),
  watchdog('watchdog'),
  failure('failure'),
  dispose('dispose');

  const PathSchedulerTraceOperation(this.wireValue);

  final String wireValue;
}

/// One retained entry of the scheduler's bounded operation trace.
class PathSchedulerTraceRecord {
  const PathSchedulerTraceRecord({
    required this.index,
    required this.operation,
    required this.generation,
    required this.path,
    required this.unit,
    required this.unitInstance,
    required this.unitFrame,
    required this.decodeOrdinal,
    required this.intendedPresentationOrdinal,
    required this.ringSize,
    required this.expectedOutputs,
    required this.reason,
  });

  final int index;
  final PathSchedulerTraceOperation operation;
  final int? generation;
  final String? path;
  final String? unit;
  final int? unitInstance;
  final int? unitFrame;
  final int? decodeOrdinal;
  final BigInt? intendedPresentationOrdinal;
  final int ringSize;
  final int expectedOutputs;
  final String? reason;
}

/// Observable scheduler snapshot, extending the runtime scheduler snapshot.
class PathSchedulerSnapshot extends RuntimeSchedulerSnapshot {
  const PathSchedulerSnapshot({
    required super.generation,
    required super.activePath,
    required super.sourceCursor,
    required super.submittedCursor,
    required super.decodedCursor,
    required super.displayedCursor,
    required super.ringSize,
    required super.ringCapacity,
    required super.smoothSession,
    required this.status,
    required this.pendingEdge,
    required this.expectedOutputs,
    required this.residentFrames,
    required this.discardedDependencyFrames,
    required this.staleFrames,
    required this.nextDecodeOrdinal,
    required this.submittedSource,
    required this.displayedSource,
    required this.unresolvedMaximumSubmitted,
  });

  final PathSchedulerStatus status;
  final String? pendingEdge;
  final int expectedOutputs;
  final int residentFrames;
  final int discardedDependencyFrames;
  final int staleFrames;
  final int nextDecodeOrdinal;
  final SourceBodyCursor? submittedSource;
  final SourceBodyCursor? displayedSource;
  final SourceBodyCursor? unresolvedMaximumSubmitted;
}
