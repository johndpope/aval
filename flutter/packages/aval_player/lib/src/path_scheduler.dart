/// One sequential decoder path: graph-selected edge in, frame plans out.
///
/// Direct port of `packages/player-web/src/runtime/path-scheduler.ts`. TS
/// `Promise` → `Future`; discriminated-union `kind` checks map onto Dart
/// `is`/pattern matches over the ported sealed classes; `bigint` → `BigInt`.
/// The failure classifier reads `DecoderWorkerError.name` for the only named
/// error the tests observe (the watchdog); any other error yields
/// `"unknown-failure"` — the JS `error instanceof Error ? error.name` fallback
/// has no exact Dart analog for core errors (`RangeError` etc.), but the trace
/// *operation* it produces (`failure`) is identical, and only the watchdog case
/// is asserted (path-scheduler.ts:794).
library;

import 'package:aval_graph/aval_graph.dart';

import 'decoder_worker/client_support.dart' show DecoderWorkerError;
import 'decoder_worker/protocol.dart';
import 'edge_lead.dart';
import 'model.dart';
import 'path_scheduler_cursor_ledger.dart';
import 'path_scheduler_generation.dart';
import 'path_scheduler_model.dart';
import 'path_scheduler_output.dart';
import 'path_scheduler_pump.dart';
import 'path_scheduler_reservation.dart';
import 'path_scheduler_resident_runway.dart';
import 'path_scheduler_route.dart';
import 'path_scheduler_trace.dart';
import 'path_scheduler_validation.dart';
import 'path_sequence.dart';
import 'platform.dart';
import 'presentation_ring.dart' show validatePresentationRingCapacity;
import 'rational_time.dart' show maxSafeInteger;
import 'submission_horizon.dart';
import 'worker_samples.dart' show WorkerSampleFactory;

/// An in-flight replacement's identity plus the worker acknowledgement to await.
class _PathSchedulerReplacementActivation {
  const _PathSchedulerReplacementActivation({
    required this.retiredGeneration,
    required this.generation,
    required this.serial,
    required this.activation,
  });

  final int retiredGeneration;
  final int generation;
  final int serial;
  final Future<void> activation;
}

/// Owns one sequential decoder path. Graph routing and future settlement stay
/// outside this class; callers supply the already-selected edge.
class PathScheduler {
  PathScheduler(PathSchedulerOptions options)
      : _samples = options.samples,
        _worker = options.worker,
        _ringCapacity = options.ringCapacity,
        _limits = options.limits,
        _maxBatchSamples = _resolveMaxBatchSamples(options) {
    validatePresentationRingCapacity(options.ringCapacity);
    validateSchedulerLimits(options.limits);
    validateSchedulerId(options.rendition, 'scheduler rendition');
    _output = PathSchedulerOutput(PathSchedulerOutputOptions(
      worker: options.worker,
      rendition: options.rendition,
      ringCapacity: options.ringCapacity,
      clock: options.clock,
      onTrace: (operation, output, reason) {
        _trace(operation, output, reason);
      },
    ));
    _generationOwner = PathSchedulerGeneration(PathSchedulerGenerationOptions(
      timeline: options.timeline,
      worker: options.worker,
      output: _output,
    ));
    _residentRunwayOwner =
        PathSchedulerResidentRunwayOwner(PathSchedulerResidentRunwayOwnerOptions(
      rendition: options.rendition,
      generation: _generationOwner,
      output: _output,
      route: _routeOwner,
      cursors: _cursorLedger,
      reservation: _reservationOwner,
    ));
  }

  static int _resolveMaxBatchSamples(PathSchedulerOptions options) {
    final maxBatchSamples = options.maxBatchSamples ??
        (options.limits.maxPendingSamples < options.limits.maxOutstandingFrames
            ? options.limits.maxPendingSamples
            : options.limits.maxOutstandingFrames);
    if (maxBatchSamples < 1 ||
        maxBatchSamples > maxSafeInteger ||
        maxBatchSamples > options.limits.maxPendingSamples ||
        maxBatchSamples > options.limits.maxOutstandingFrames) {
      throw RangeError('path scheduler batch limit is invalid');
    }
    return maxBatchSamples;
  }

  final WorkerSampleFactory _samples;
  final PathSchedulerWorkerAdapter _worker;
  final int _ringCapacity;
  final DecoderWorkerLimits _limits;
  final int _maxBatchSamples;
  final PathSchedulerTraceLog _traceLog = PathSchedulerTraceLog();
  late final PathSchedulerOutput _output;
  late final PathSchedulerGeneration _generationOwner;
  final PathSchedulerRoute _routeOwner = PathSchedulerRoute();
  final PathSchedulerCursorLedger _cursorLedger = PathSchedulerCursorLedger();
  final PathSchedulerReservationOwner _reservationOwner =
      PathSchedulerReservationOwner();
  late final PathSchedulerResidentRunwayOwner _residentRunwayOwner;

  PathSchedulerStatus _status = PathSchedulerStatus.idle;
  bool _smoothSession = true;
  PathSequenceState? _build;
  int _replacementSerial = 0;

  // Resident recovery is a target path without a graph-owned streaming edge.
  ResidentPathTarget? _residentTarget;

  Future<void> startBody(StartScheduledBodyInput input) async {
    _requireStatus(PathSchedulerStatus.idle);
    validateSchedulerId(input.state, 'source state');
    validateSchedulerId(input.path, 'scheduler path');
    validateScheduledBody(input.body);
    final firstPresentationOrdinal =
        input.firstPresentationOrdinal ?? BigInt.zero;
    if (firstPresentationOrdinal < BigInt.zero) {
      throw RangeError('first presentation ordinal must be non-negative');
    }

    _build = _cursorLedger.startSource(
      state: input.state,
      body: input.body,
      outgoingStarts: input.outgoingStarts,
      firstPresentationOrdinal: firstPresentationOrdinal,
    );
    try {
      await _generationOwner.start(input.path);
      _status = PathSchedulerStatus.active;
      _trace(PathSchedulerTraceOperation.activate, null, null);
    } catch (error) {
      _status = PathSchedulerStatus.error;
      _smoothSession = false;
      rethrow;
    }
  }

  Future<SubmissionHorizonDecision> prepareRoute(
    PrepareScheduledRouteInput input,
  ) async {
    _requireActive();
    if (_cursorLedger.displayedSource == null ||
        _cursorLedger.sourceBody == null) {
      throw RangeError('a source frame must be displayed before routing');
    }
    if (input.edge.transition is GraphTransitionReversible) {
      throw RangeError(
        'resident reversible motion is not a streaming path segment',
      );
    }
    validateScheduledBody(input.targetBody);
    validateSchedulerId(input.targetState, 'target state');
    if (_routeOwner.committed) {
      throw RangeError('a committed path cannot be replaced');
    }

    if (_routeOwner.current?.edge.id == input.edge.id) {
      final current = routeDecision();
      if (current == null) {
        throw StateError('pending route decision disappeared');
      }
      return current;
    }
    if (_routeOwner.current != null) {
      await _restartForReplacement(
        input.replacementPath ?? input.edge.id,
        input.signal,
        input.preserveReservedSource == true,
      );
    }

    final decision = _calculateRouteDecision(input.edge);
    if (decision is SubmissionHorizonRejectReadiness) {
      return decision;
    }
    if (decision is SubmissionHorizonRestartGeneration) {
      return decision;
    }
    final boundary = _decisionBoundary(decision);
    _routeOwner.prepare(
      edge: input.edge,
      targetState: input.targetState,
      targetBody: input.targetBody,
      boundary: boundary,
    );
    final build = _requireBuild();
    if (build.phase == PathSequencePhase.done) {
      build.phase = PathSequencePhase.source;
      build.sourceNext = null;
    }
    build.sourceStop =
        SourceBodyCursor(occurrence: boundary.occurrence, frame: boundary.frame);
    _trace(PathSchedulerTraceOperation.routeSelect, null, input.edge.id);
    return decision;
  }

  /// Cancels only an uncommitted route and retains the displayed source.
  Future<void> cancelPreparedRoute(
    String replacementPath, [
    AbortSignal? signal,
    bool preserveReservedSource = false,
  ]) async {
    _requireActive();
    if (_routeOwner.current == null) return;
    if (_routeOwner.committed) {
      throw RangeError('a committed path cannot be cancelled');
    }
    await _restartForReplacement(
      replacementPath,
      signal,
      preserveReservedSource,
    );
  }

  /// Adopts a resident body pixel only after its successful draw barrier.
  Future<void> adoptResidentBodyCheckpoint({
    required String state,
    required GraphBodyDefinition body,
    required List<GraphStartPolicy> outgoingStarts,
    required int frame,
    required int unitInstance,
    required BigInt presentationOrdinal,
    required String path,
    AbortSignal? signal,
  }) async {
    _requireActive();
    validateSchedulerId(state, 'resident checkpoint state');
    validateScheduledBody(body);
    if (frame < 0 ||
        frame > maxSafeInteger ||
        frame >= body.frameCount ||
        presentationOrdinal < BigInt.zero) {
      throw RangeError('resident body checkpoint is invalid');
    }
    final replacement = _beginReplacementGeneration(path, signal);
    await _settleReplacementGeneration(replacement, signal);
    _routeOwner.clear();
    _residentTarget = null;
    _build = _cursorLedger.replaceSource(
      PathSchedulerSourceReplacementResidentCheckpoint(
        state: state,
        body: body,
        outgoingStarts: outgoingStarts,
        frame: frame,
        unitInstance: unitInstance,
        presentationOrdinal: presentationOrdinal,
        path: path,
      ),
    );
  }

  SubmissionHorizonDecision? routeDecision() {
    _requireActive();
    final route = _routeOwner.current;
    if (route == null) return null;
    final decision = _calculateRouteDecision(route.edge);
    final boundary = _routeOwner.reconcileBoundary(
      decision,
      _requireBuild().edgeSubmissionStarted,
    );
    if (boundary != null) {
      _requireBuild().sourceStop = SourceBodyCursor(
        occurrence: boundary.occurrence,
        frame: boundary.frame,
      );
    }
    return decision;
  }

  void commitPreparedRoute() {
    _requireActive();
    final decision = routeDecision();
    if (decision is! SubmissionHorizonCommitEdge) {
      throw RangeError('route cannot commit without its exact prepared lead');
    }
    _routeOwner.commit();
    _trace(
      PathSchedulerTraceOperation.routeCommit,
      null,
      _routeOwner.pendingEdge,
    );
  }

  /// Reserves exact generation and resident metadata without replacing the
  /// currently visible source. The returned token is the sole commit key.
  PathSchedulerResidentRunwayTransaction stageResidentRunway(
    StartResidentRunwayInput input,
  ) {
    _requireActive();
    return _residentRunwayOwner.stage(input);
  }

  /// Installs a staged runway synchronously at the draw barrier. Only the
  /// worker acknowledgement remains asynchronous and is returned to the lane.
  PathSchedulerWorkerActivation commitResidentRunway(
    PathSchedulerResidentRunwayTransaction transaction, [
    CommitResidentRunwayOptions options = const CommitResidentRunwayOptions(),
  ]) {
    _requireActive();
    final committed = _residentRunwayOwner.commit(transaction, options);
    _build = committed.build;
    _residentTarget = committed.residentTarget;
    if (committed.firstPresented != null) {
      _trace(
        PathSchedulerTraceOperation.residentPresent,
        null,
        null,
        committed.firstPresented,
      );
    }
    _trace(
      PathSchedulerTraceOperation.generationRetire,
      null,
      committed.retiredGeneration.toString(),
    );
    _trace(PathSchedulerTraceOperation.activate, null, null);
    return committed.activateWorker;
  }

  /// Invalidates only the matching uncommitted transaction.
  bool rollbackResidentRunway(
    PathSchedulerResidentRunwayTransaction transaction,
  ) {
    return _residentRunwayOwner.rollback(transaction);
  }

  Future<void> startResidentRunway(StartResidentRunwayInput input) async {
    final transaction = stageResidentRunway(input);
    final activateWorker = commitResidentRunway(transaction);
    await abortablePathSchedulerActivation(activateWorker(), input.signal);
  }

  Future<PathSchedulerPumpReport> pump([
    PathSchedulerPumpOptions options = const PathSchedulerPumpOptions(),
  ]) async {
    _requireActive();
    try {
      return await pumpPathScheduler(PumpPathSchedulerInput(
        options: options,
        ringCapacity: _ringCapacity,
        limits: _limits,
        maxBatchSamples: _maxBatchSamples,
        worker: _worker,
        samples: _samples,
        output: _output,
        build: _requireBuild(),
        buildFrame: (state) => buildNextPathFrame(
          state,
          PathSequenceContext(
            sourceState: _cursorLedger.sourceState,
            sourceBody: _cursorLedger.sourceBody,
            route: _routeOwner.current,
            residentTarget: _residentTarget,
            canSubmitSource: (cursor) =>
                _sourceWithinUnresolvedHorizon(cursor),
          ),
        ),
        commitBuild: (state) {
          _build = state;
        },
        recordSubmitted: (outputs) => _recordSubmitted(outputs),
        onDrain: (report) => _recordDrain(report),
      ));
    } catch (error) {
      final signal = options.signal;
      if (signal != null && signal.aborted) {
        throw signal.reason ??
            DOMException('the operation was aborted', 'AbortError');
      }
      await _fail(error);
      rethrow;
    }
  }

  PathSchedulerTakeResult takeNext() {
    final result = reserveNext();
    if (result is PathSchedulerTakeFrame) {
      commitPreparedPresentation(result.media);
    } else if (result is PathSchedulerTakeResident) {
      commitPreparedPresentation(result.media);
    }
    return result;
  }

  /// Removes one ready frame from the ring without claiming it was drawn.
  PathSchedulerTakeResult reserveNext([bool allowPreparedRoute = false]) {
    _requireActive();
    _reservationOwner.requireEmpty();
    final resident = _output.takeResident();
    if (resident != null) {
      _reservationOwner.reserve(PathSchedulerPresentationReservation(
        media: resident,
        output: null,
        commitRoute: false,
      ));
      return PathSchedulerTakeResident(media: resident);
    }

    return _reserveNextStreaming(allowPreparedRoute);
  }

  /// Reserves the decoded continuation behind a resident runway without
  /// consuming its presentation queue. Resident coordinators own those pixels.
  PathSchedulerTakeResult takeStreamingContinuation() {
    _requireActive();
    _reservationOwner.requireEmpty();
    return _reserveNextStreaming(false);
  }

  /// Commits the sole reserved frame only after its successful draw barrier.
  void commitPreparedPresentation(RuntimeMediaPresentationFrame media) {
    _requireActive();
    final reserved = _reservationOwner.consume(media);
    if (reserved.commitRoute) {
      _routeOwner.commit();
      _trace(
        PathSchedulerTraceOperation.routeCommit,
        null,
        _routeOwner.pendingEdge,
      );
    }
    if (reserved.output == null) {
      _cursorLedger.recordResidentDisplayed(media);
      _trace(PathSchedulerTraceOperation.residentPresent, null, null, media);
    } else {
      _recordDisplayed(reserved.output!, media);
      _trace(PathSchedulerTraceOperation.present, reserved.output, null, media);
    }
  }

  /// Consumes matching resident metadata drawn by a persistent cache owner.
  void commitResidentPresentation(RuntimeMediaPresentationFrame media) {
    _requireActive();
    final resident = _output.takeResident();
    if (resident == null || !sameSchedulerMediaIdentity(resident, media)) {
      throw RangeError('scheduler resident presentation diverged');
    }
    _cursorLedger.recordResidentDisplayed(media);
    _trace(PathSchedulerTraceOperation.residentPresent, null, null, media);
  }

  /// Atomically adopts a completed target as the next routable source.
  void promoteTargetToSource({
    required String state,
    required GraphBodyDefinition body,
    required List<GraphStartPolicy> outgoingStarts,
  }) {
    _requireActive();
    _reservationOwner.requireEmpty();
    final routeTarget = _routeOwner.current;
    final targetState =
        routeTarget?.targetState ?? _residentTarget?.targetState;
    final targetBody = routeTarget?.targetBody ?? _residentTarget?.targetBody;
    if (targetState != state ||
        targetBody?.unitId != body.unitId ||
        _cursorLedger.displayedTarget == null) {
      throw RangeError('scheduler target cannot be promoted to this source');
    }
    _output.promoteTargetToSource(state, body);
    promoteTargetSequenceToSource(_requireBuild(), body);
    _cursorLedger.promoteTargetToSource(
      state: state,
      body: body,
      outgoingStarts: outgoingStarts,
    );
    _residentTarget = null;
    _routeOwner.clear();
  }

  void discardPreparedPresentation() {
    _reservationOwner.discard();
  }

  /// Records a held-body repeat that reuses the last uploaded pixels.
  void commitHeldPresentation(BigInt ordinal) {
    _requireActive();
    _reservationOwner.requireEmpty();
    _cursorLedger.recordHeld(ordinal);
    _requireBuild().nextPresentationOrdinal = ordinal + BigInt.one;
  }

  PathSchedulerTakeResult _reserveNextStreaming(bool allowPreparedRoute) {
    final next = _output.peekRingOutput();
    if (next != null) {
      var commitRoute = false;
      if (next.plan.purpose != PathSchedulerFramePurpose.source &&
          _routeOwner.current != null &&
          !_routeOwner.committed) {
        if (!allowPreparedRoute ||
            routeDecision() is! SubmissionHorizonCommitEdge) {
          return const PathSchedulerTakeRouteBlocked();
        }
        commitRoute = true;
      }
      if (next.plan.purpose == PathSchedulerFramePurpose.bridge &&
          !_lockedBridgeLeadReady()) {
        return _underflow();
      }
      final result = _output.takeRingOutput();
      if (result is PathSchedulerRingTakeUnderflow) {
        return _underflow();
      }
      final frameResult = result as PathSchedulerRingTakeFrame;
      final media = _output.mediaFor(frameResult.output);
      _reservationOwner.reserve(PathSchedulerPresentationReservation(
        media: media,
        output: frameResult.output,
        commitRoute: commitRoute,
      ));
      return PathSchedulerTakeFrame(
        purpose: next.plan.purpose,
        media: media,
        frame: frameResult.frame,
      );
    }

    if (_output.hasExpected() || _buildHasMoreFrames()) {
      return _underflow();
    }
    return const PathSchedulerTakeHeld();
  }

  PathSchedulerSnapshot snapshot() {
    final cursors = _cursorLedger.snapshot();
    final sourceCursor = cursors.sourceCursor;
    return PathSchedulerSnapshot(
      generation: _generationOwner.current,
      activePath: _generationOwner.path,
      sourceCursor: sourceCursor == null
          ? null
          : RuntimeMediaCursor(
              path: _generationOwner.path ?? '',
              unit: sourceCursor.unit,
              unitInstance: sourceCursor.unitInstance,
              localFrame: sourceCursor.localFrame,
            ),
      submittedCursor: cursors.submittedCursor,
      decodedCursor: cursors.decodedCursor,
      displayedCursor: cursors.displayedCursor,
      ringSize: _output.ringSize,
      ringCapacity: _ringCapacity,
      smoothSession: _smoothSession,
      status: _status,
      pendingEdge: _routeOwner.pendingEdge,
      expectedOutputs: _output.expectedCount,
      residentFrames: _output.residentCount,
      discardedDependencyFrames: _output.discardedDependencyFrames,
      staleFrames: _output.staleFrames,
      nextDecodeOrdinal: _generationOwner.nextDecodeOrdinal,
      submittedSource: cursors.submittedSource,
      displayedSource: cursors.displayedSource,
      unresolvedMaximumSubmitted: _unresolvedMaximumSubmitted(),
    );
  }

  List<PathSchedulerTraceRecord> trace() {
    return _traceLog.snapshot();
  }

  Future<void> dispose() async {
    if (_status == PathSchedulerStatus.disposed) return;
    _residentRunwayOwner.clear();
    _reservationOwner.discard();
    _output.dispose();
    await _generationOwner.dispose();
    _status = PathSchedulerStatus.disposed;
    _trace(PathSchedulerTraceOperation.dispose, null, null);
  }

  void _recordSubmitted(List<PathSchedulerExpectedOutput> outputs) {
    _cursorLedger.recordSubmitted(outputs, _requirePath());
    for (final output in outputs) {
      _trace(PathSchedulerTraceOperation.submit, output, null);
    }
  }

  void _recordDrain(PathSchedulerOutputDrainReport report) {
    _cursorLedger.recordDrain(report);
  }

  SubmissionHorizonDecision _calculateRouteDecision(GraphEdgeDefinition edge) {
    final body = _cursorLedger.sourceBody;
    final displayed = _cursorLedger.displayedSource;
    if (body == null || displayed == null) {
      throw RangeError('route decision requires a displayed source cursor');
    }
    return _routeOwner.decide(
      edge,
      PathSchedulerRouteDecisionInput(
        body: body,
        displayed: displayed,
        submitted: _cursorLedger.submittedSource ?? displayed,
        ringCapacity: _ringCapacity,
        availableConsecutiveEdgeFrames: _availableEdgeLead(),
      ),
    );
  }

  int _availableEdgeLead() {
    return _output.availableEdgeLead();
  }

  bool _lockedBridgeLeadReady() {
    final transition = _routeOwner.current?.edge.transition;
    if (transition is! GraphTransitionLocked) return true;
    return planEdgeLead(EdgeLeadInput(
      transitionFrames: transition.frameCount,
      ringCapacity: _ringCapacity,
      availableConsecutiveFrames: _availableEdgeLead(),
    )).ready;
  }

  void _recordDisplayed(
    PathSchedulerExpectedOutput output,
    RuntimeMediaPresentationFrame media,
  ) {
    if (_cursorLedger.recordDisplayed(output, media)) {
      _routeOwner.noteDisplayedSource();
    }
  }

  Future<void> _restartForReplacement(
    String path, [
    AbortSignal? signal,
    bool preserveReservedSource = false,
  ]) async {
    final body = _cursorLedger.sourceBody;
    final displayed = _cursorLedger.displayedSource;
    if (body == null || displayed == null) {
      throw RangeError('route replacement requires a displayed source');
    }
    final reserved =
        preserveReservedSource ? _reservationOwner.current : null;
    final reservedSource = reserved?.output?.plan.sourceCursor;
    if (preserveReservedSource &&
        (reserved == null ||
            reserved.output?.plan.purpose !=
                PathSchedulerFramePurpose.source ||
            reservedSource == null)) {
      throw RangeError(
        'route replacement can preserve only a source reservation',
      );
    }
    final checkpoint = reservedSource ?? displayed;
    final replacement = _beginReplacementGeneration(
      path,
      signal,
      preserveReservedSource,
    );
    _routeOwner.clear();
    final firstPresentationOrdinal = reserved == null
        ? (_cursorLedger.lastDisplayedOrdinal ?? -BigInt.one) + BigInt.one
        : reserved.media.intendedPresentationOrdinal + BigInt.one;
    _build = _cursorLedger.replaceSource(
      PathSchedulerSourceReplacementRouteRestart(
        checkpoint: checkpoint,
        firstPresentationOrdinal: firstPresentationOrdinal,
      ),
    );
    await _settleReplacementGeneration(replacement, signal);
  }

  _PathSchedulerReplacementActivation _beginReplacementGeneration(
    String path, [
    AbortSignal? signal,
    bool preserveReservation = false,
  ]) {
    if (signal?.aborted == true) {
      throw signal!.reason ??
          DOMException('the operation was aborted', 'AbortError');
    }
    if (_residentRunwayOwner.locked) {
      throw RangeError(
        'path scheduler generation is locked by a staged resident runway',
      );
    }
    validateSchedulerId(path, 'replacement path');
    final oldGeneration = _requireGeneration();
    if (!preserveReservation) _reservationOwner.discard();
    final serial = checkedPathSchedulerSerial(_replacementSerial);
    _replacementSerial = serial;
    final committed = _generationOwner.commitReplacement(
      _generationOwner.planReplacement(path),
    );
    return _PathSchedulerReplacementActivation(
      retiredGeneration: oldGeneration,
      generation: committed.generation,
      serial: serial,
      activation: committed.activateWorker(),
    );
  }

  Future<void> _settleReplacementGeneration(
    _PathSchedulerReplacementActivation replacement, [
    AbortSignal? signal,
  ]) async {
    await abortablePathSchedulerActivation(replacement.activation, signal);
    if (replacement.serial != _replacementSerial ||
        replacement.generation != _generationOwner.current) {
      throw DOMException(
        'path scheduler activation was superseded',
        'AbortError',
      );
    }
    _trace(
      PathSchedulerTraceOperation.generationRetire,
      null,
      replacement.retiredGeneration.toString(),
    );
    _trace(PathSchedulerTraceOperation.activate, null, null);
  }

  Future<void> _fail(Object error) async {
    if (_status != PathSchedulerStatus.active) return;
    _smoothSession = false;
    _status = PathSchedulerStatus.error;
    try {
      _output.clear();
    } catch (_) {
      // Preserve the initiating failure; managed handles are close-once.
    }
    try {
      await _generationOwner.abortActive();
    } catch (_) {
      // Preserve the initiating failure.
    }
    final failureName =
        error is DecoderWorkerError ? error.name : 'unknown-failure';
    _trace(
      failureName.contains('Watchdog')
          ? PathSchedulerTraceOperation.watchdog
          : PathSchedulerTraceOperation.failure,
      null,
      failureName,
    );
  }

  PathSchedulerTakeResult _underflow() {
    _smoothSession = false;
    _trace(
      PathSchedulerTraceOperation.underflow,
      _output.peekRingOutput(),
      null,
    );
    return const PathSchedulerTakeUnderflow();
  }

  bool _sourceWithinUnresolvedHorizon(SourceBodyCursor proposed) {
    final body = _cursorLedger.sourceBody;
    final outgoingStarts = _cursorLedger.outgoingStarts;
    if (outgoingStarts.isEmpty || body == null) {
      return true;
    }
    final displayed = _cursorLedger.displayedSource ??
        SourceBodyCursor(occurrence: BigInt.zero, frame: 0);
    final result = planUnresolvedSubmissionHorizon(
      UnresolvedSubmissionHorizonInput(
        body: body,
        displayed: displayed,
        submitted: proposed,
        outgoingStarts: outgoingStarts,
        ringCapacity: _ringCapacity,
      ),
    );
    return result.submittedWithinHorizon;
  }

  SourceBodyCursor? _unresolvedMaximumSubmitted() {
    final body = _cursorLedger.sourceBody;
    final outgoingStarts = _cursorLedger.outgoingStarts;
    if (body == null ||
        outgoingStarts.isEmpty ||
        _routeOwner.current != null) {
      return null;
    }
    final displayed = _cursorLedger.displayedSource ??
        SourceBodyCursor(occurrence: BigInt.zero, frame: 0);
    final submitted = _cursorLedger.submittedSource ?? displayed;
    try {
      return planUnresolvedSubmissionHorizon(
        UnresolvedSubmissionHorizonInput(
          body: body,
          displayed: displayed,
          submitted: submitted,
          outgoingStarts: outgoingStarts,
          ringCapacity: _ringCapacity,
        ),
      ).maximumSubmitted;
    } catch (_) {
      return null;
    }
  }

  bool _buildHasMoreFrames() {
    final build = _build;
    return build != null && build.phase != PathSequencePhase.done;
  }

  void _trace(
    PathSchedulerTraceOperation operation,
    PathSchedulerExpectedOutput? output,
    String? reason, [
    RuntimeMediaPresentationFrame? media,
  ]) {
    _traceLog.append(PathSchedulerTraceInput(
      operation: operation,
      generation: _generationOwner.current,
      path: _generationOwner.path,
      unit: output?.sample.unitId ?? media?.frame.unit,
      unitInstance: output?.sample.unitInstance ?? media?.unitInstance,
      unitFrame: output?.sample.unitFrame ?? media?.frame.localFrame,
      decodeOrdinal: output?.sample.ordinal ?? media?.decodeOrdinal,
      intendedPresentationOrdinal: output?.plan.intendedPresentationOrdinal ??
          media?.intendedPresentationOrdinal,
      ringSize: _output.ringSize,
      expectedOutputs: _output.expectedCount,
      reason: reason,
    ));
  }

  void _requireStatus(PathSchedulerStatus expected) {
    if (_status != expected) {
      throw RangeError('path scheduler must be ${expected.wireValue}');
    }
  }

  void _requireActive() {
    _requireStatus(PathSchedulerStatus.active);
  }

  int _requireGeneration() {
    return _generationOwner.requireGeneration();
  }

  String _requirePath() {
    return _generationOwner.requirePath();
  }

  PathSequenceState _requireBuild() {
    final build = _build;
    if (build == null) {
      throw RangeError('path scheduler has no active build state');
    }
    return build;
  }
}

/// Extracts the source boundary from a decision that is neither a readiness
/// rejection nor a cut restart (both handled by the caller before this runs).
SourceBoundary _decisionBoundary(SubmissionHorizonDecision decision) {
  return switch (decision) {
    SubmissionHorizonContinueSource(:final boundary) => boundary,
    SubmissionHorizonSelectPortal(:final boundary) => boundary,
    SubmissionHorizonCommitEdge(:final boundary) => boundary,
    SubmissionHorizonWaitHeld(:final boundary) => boundary,
    SubmissionHorizonRejectReadiness() =>
      throw StateError('reject-readiness has no boundary'),
    SubmissionHorizonRestartGeneration() =>
      throw StateError('restart-generation has no boundary'),
  };
}
