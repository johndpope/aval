/// Golden-trace parity test: drives the *identical* deterministic scenario as
/// the TS harness (`packages/player-web/src/runtime/grass-rabbit-golden-trace.
/// test.ts`) through the Dart [PathScheduler] — with the real
/// [WorkerSampleFactory] + [RuntimeAssetCatalog] over the real grass-rabbit.avl
/// and a byte-identical fake decoder worker — and diffs the resulting trace +
/// takeNext media sequence against the committed golden JSON.
///
/// The golden fixture (test/fixtures/grass_rabbit_golden_trace.json) is
/// regenerated from the TS side with:
///   WRITE_GOLDEN=1 npx vitest run --config vitest.m9.config.ts \
///     packages/player-web/src/runtime/grass-rabbit-golden-trace.test.ts
///
/// This closes the Phase-2 architecture exit criterion: "the scheduler produces
/// the identical PathFramePlan sequence as the TS version for grass-rabbit
/// (golden-trace diff)".
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aval_format/aval_format.dart' show BodyUnitV01;
import 'package:aval_graph/aval_graph.dart';
import 'package:aval_player/aval_player.dart';
import 'package:test/test.dart';

const DecoderWorkerLimits _limits = DecoderWorkerLimits(
  maxDecodeQueueSize: 8,
  maxPendingSamples: 12,
  maxOutstandingFrames: 12,
  maxDecodedBytes: 12 * 1280 * 720 * 4,
);

const int _ringCapacity = 6;
const int _idleTicks = 80;

void main() {
  test('Dart PathScheduler matches the TS golden trace for grass-rabbit',
      () async {
    final fixture =
        jsonDecode(_readText(_fixturePath())) as Map<String, dynamic>;
    final actual = await _runScenario();

    // Metadata (rendition id, frame rate, unit frame counts) must match first;
    // a mismatch here means the parsed asset diverged.
    expect(actual['meta'], fixture['meta'], reason: 'meta mismatch');

    final expectedMedia = fixture['media'] as List<dynamic>;
    final actualMedia = actual['media'] as List<Object?>;
    expect(actualMedia.length, expectedMedia.length,
        reason: 'media length mismatch');
    for (var index = 0; index < expectedMedia.length; index += 1) {
      expect(actualMedia[index], expectedMedia[index],
          reason: 'media[$index] mismatch');
    }

    final expectedTrace = fixture['trace'] as List<dynamic>;
    final actualTrace = actual['trace'] as List<Object?>;
    expect(actualTrace.length, expectedTrace.length,
        reason: 'trace length mismatch');
    for (var index = 0; index < expectedTrace.length; index += 1) {
      expect(actualTrace[index], expectedTrace[index],
          reason: 'trace[$index] mismatch');
    }
  });
}

Future<Map<String, Object?>> _runScenario() async {
  final bytes = Uint8List.fromList(File(_assetPath()).readAsBytesSync());
  final catalog = installRuntimeAssetCatalog(bytes);
  final manifest = catalog.manifest;
  final rendition = manifest.renditions
      .firstWhere((candidate) => candidate.profile.startsWith('avc-annexb'));
  final timeline = DecodeTimeline(RationalFrameRate(
    numerator: manifest.frameRate.numerator,
    denominator: manifest.frameRate.denominator,
  ));
  final worker = _FakeWorker();
  final samples = WorkerSampleFactory(WorkerSampleFactoryOptions(
    catalog: catalog,
    timeline: timeline,
    rendition: rendition.id,
    limits: _limits,
  ));
  var now = 0;
  final scheduler = PathScheduler(PathSchedulerOptions(
    timeline: timeline,
    samples: samples,
    worker: worker,
    rendition: rendition.id,
    ringCapacity: _ringCapacity,
    limits: _limits,
    clock: _InlineClock(() => ++now),
  ));

  final unitFrameCounts = <String, int>{};
  for (final unit in manifest.units) {
    unitFrameCounts[unit.id] = unit.frameCount;
  }

  final media = <Object?>[];
  final step = _StepBox();
  void record(String label, PathSchedulerTakeResult result) {
    media.add(_serializeTake(step.value, label, result));
    step.value += 1;
    if (result is PathSchedulerTakeFrame) result.frame.close();
  }

  // 1-2. Idle loop with wrap.
  await scheduler.startBody(StartScheduledBodyInput(
    state: 'idle',
    body: _body(manifest, 'idle-loop'),
    outgoingStarts: [_portalStart('default', 'default', 139)],
    path: 'idle',
  ));
  for (var index = 0; index < _idleTicks; index += 1) {
    await scheduler.pump(const PathSchedulerPumpOptions(
      targetRingFrames: _ringCapacity,
    ));
    record('idle', scheduler.takeNext());
  }

  // 3. hover.enter -> entering (portal edge).
  await _routeThrough(
    scheduler,
    _portalEdge('idle.entering', 'idle', 'entering', 'default', 'default', 139),
    'entering',
    _body(manifest, 'hover-in'),
    'enter',
    media,
    step,
  );

  // 4. hover.leave -> exiting (finish edge from the finite hover-in body).
  await _routeThrough(
    scheduler,
    _finishEdge('entering.exiting', 'entering', 'exiting', 'default', 66),
    'exiting',
    _body(manifest, 'hover-out'),
    'leave',
    media,
    step,
  );

  for (var index = 0; index < 6; index += 1) {
    await scheduler.pump(const PathSchedulerPumpOptions(
      targetRingFrames: _ringCapacity,
    ));
    record('exiting-tail', scheduler.takeNext());
  }

  final trace = scheduler.trace().map(_serializeTraceRecord).toList();
  await scheduler.dispose();

  return {
    'meta': {
      'rendition': rendition.id,
      'frameRate': {
        'numerator': manifest.frameRate.numerator,
        'denominator': manifest.frameRate.denominator,
      },
      'units': unitFrameCounts,
    },
    'media': media,
    'trace': trace,
  };
}

Future<void> _routeThrough(
  PathScheduler scheduler,
  GraphEdgeDefinition edge,
  String targetState,
  GraphBodyDefinition targetBody,
  String label,
  List<Object?> media,
  _StepBox step,
) async {
  await scheduler.prepareRoute(PrepareScheduledRouteInput(
    edge: edge,
    targetState: targetState,
    targetBody: targetBody,
  ));
  var committed = false;
  for (var guard = 0; guard < 600 && !committed; guard += 1) {
    await scheduler.pump(const PathSchedulerPumpOptions(
      targetRingFrames: _ringCapacity,
    ));
    final decision = scheduler.routeDecision();
    if (decision is SubmissionHorizonCommitEdge) {
      scheduler.commitPreparedRoute();
      committed = true;
      break;
    }
    final result = scheduler.reserveNext(true);
    if (result is PathSchedulerTakeFrame) {
      scheduler.commitPreparedPresentation(result.media);
      media.add(_serializeTake(step.value, '$label-source', result));
      step.value += 1;
      result.frame.close();
    } else {
      media.add(_serializeTake(step.value, '$label-wait', result));
      step.value += 1;
    }
  }
  if (!committed) throw StateError('$label route never committed');
  for (var index = 0; index < 10; index += 1) {
    await scheduler.pump(const PathSchedulerPumpOptions(
      targetRingFrames: _ringCapacity,
    ));
    media.add(_serializeTake(step.value, '$label-target', scheduler.takeNext()));
    step.value += 1;
  }
  scheduler.promoteTargetToSource(
    state: targetState,
    body: targetBody,
    outgoingStarts: [_portalStart('default', 'default', 139)],
  );
}

GraphBodyDefinition _body(dynamic manifest, String unitId) {
  final unit = (manifest.units as List)
      .firstWhere((candidate) => candidate.id == unitId) as BodyUnitV01;
  return GraphBodyDefinition(
    unitId: unit.id,
    kind: unit.playback == 'loop' ? GraphBodyKind.loop : GraphBodyKind.finite,
    frameCount: unit.frameCount,
    ports: unit.ports
        .map((port) => GraphPortDefinition(
              id: port.id,
              portalFrames: List<int>.from(port.portalFrames),
            ))
        .toList(),
  );
}

GraphStartPolicyPortal _portalStart(
  String sourcePort,
  String targetPort,
  int maxWaitFrames,
) {
  return GraphStartPolicyPortal(
    sourcePort: sourcePort,
    targetPort: targetPort,
    maxWaitFrames: maxWaitFrames,
  );
}

GraphEdgeDefinition _portalEdge(
  String id,
  String from,
  String to,
  String sourcePort,
  String targetPort,
  int maxWaitFrames,
) {
  return GraphEdgeDefinition(
    id: id,
    from: from,
    to: to,
    start: _portalStart(sourcePort, targetPort, maxWaitFrames),
    continuity: GraphContinuity.exactAuthored,
  );
}

GraphEdgeDefinition _finishEdge(
  String id,
  String from,
  String to,
  String targetPort,
  int maxWaitFrames,
) {
  return GraphEdgeDefinition(
    id: id,
    from: from,
    to: to,
    start: GraphStartPolicyFinish(
      targetPort: targetPort,
      maxWaitFrames: maxWaitFrames,
    ),
    continuity: GraphContinuity.exactAuthored,
  );
}

Map<String, Object?> _serializeTake(
  int step,
  String label,
  PathSchedulerTakeResult result,
) {
  final base = <String, Object?>{
    'step': step,
    'label': label,
    'kind': result.kind,
  };
  if (result is PathSchedulerTakeFrame) {
    base['purpose'] = result.purpose.wireValue;
    base.addAll(_mediaFields(result.media));
    // Mirror the TS harness's serializeTake: close (release) the frame here so
    // outstanding-frame credit replenishes identically on both sides.
    result.frame.close();
  } else if (result is PathSchedulerTakeResident) {
    base.addAll(_mediaFields(result.media));
  }
  return base;
}

Map<String, Object?> _mediaFields(RuntimeMediaPresentationFrame media) {
  return {
    'graphKind': media.graphKind.wireValue,
    'state': media.state,
    'edge': media.edge,
    'path': media.path,
    'unit': media.frame.unit,
    'localFrame': media.frame.localFrame,
    'drawSource': media.drawSource.wireValue,
    'generation': media.generation,
    'unitInstance': media.unitInstance,
    'decodeOrdinal': media.decodeOrdinal,
    'timestamp': media.timestamp,
    'intendedPresentationOrdinal': media.intendedPresentationOrdinal.toString(),
  };
}

Map<String, Object?> _serializeTraceRecord(PathSchedulerTraceRecord record) {
  return {
    'index': record.index,
    'operation': record.operation.wireValue,
    'generation': record.generation,
    'path': record.path,
    'unit': record.unit,
    'unitInstance': record.unitInstance,
    'unitFrame': record.unitFrame,
    'decodeOrdinal': record.decodeOrdinal,
    'intendedPresentationOrdinal':
        record.intendedPresentationOrdinal?.toString(),
    'ringSize': record.ringSize,
    'expectedOutputs': record.expectedOutputs,
    'reason': record.reason,
  };
}

String _readText(String path) => File(path).readAsStringSync();

String _fixturePath() {
  for (final candidate in [
    'test/fixtures/grass_rabbit_golden_trace.json',
    'fixtures/grass_rabbit_golden_trace.json',
  ]) {
    if (File(candidate).existsSync()) return candidate;
  }
  return 'test/fixtures/grass_rabbit_golden_trace.json';
}

String _assetPath() {
  for (final candidate in [
    '../../../examples/grass-rabbit/public/grass-rabbit.avl',
    '../../../../examples/grass-rabbit/public/grass-rabbit.avl',
  ]) {
    if (File(candidate).existsSync()) return candidate;
  }
  return '../../../examples/grass-rabbit/public/grass-rabbit.avl';
}

class _StepBox {
  int value = 0;
}

class _InlineClock implements PathSchedulerClock {
  _InlineClock(this._now);
  final int Function() _now;
  @override
  int now() => _now();
}

// --- Fake decoder worker (port of the TS harness / path_scheduler_test.dart) -

class _PendingFakeSample {
  const _PendingFakeSample(this.generation, this.sample);
  final int generation;
  final DecoderWorkerSample sample;
}

class _FakeWorker implements PathSchedulerWorkerAdapter {
  @override
  int? activeGeneration;
  final int _outputsPerWait = 1;
  final List<_PendingFakeSample> _pending = <_PendingFakeSample>[];
  final List<_FakeManagedFrame> _ready = <_FakeManagedFrame>[];
  final Set<_FakeManagedFrame> _open = <_FakeManagedFrame>{};
  int _acceptedSamples = 0;
  int _releasedFrames = 0;

  @override
  int get queuedFrames => _ready.length;

  @override
  int get openFrames => _open.length;

  @override
  Future<void> activateGeneration(int generation) async {
    activeGeneration = generation;
    for (final frame in [..._ready]) {
      if (frame.generation != generation) frame.close();
    }
    _ready.removeWhere((frame) => frame.closed);
    _pending.clear();
  }

  @override
  Future<void> submit(int generation, List<DecoderWorkerSample> samples) async {
    if (generation != activeGeneration) {
      throw StateError('fake generation mismatch');
    }
    for (final sample in samples) {
      _pending.add(_PendingFakeSample(generation, sample));
      _acceptedSamples += 1;
    }
  }

  @override
  Future<void> abortGeneration(int generation) async {
    _pending.removeWhere((item) => item.generation == generation);
    for (final frame in [..._open]) {
      if (frame.generation == generation) frame.close();
    }
    _ready.removeWhere((frame) => frame.closed);
    if (activeGeneration == generation) activeGeneration = null;
  }

  @override
  ManagedDecoderWorkerFrame? takeFrame() =>
      _ready.isEmpty ? null : _ready.removeAt(0);

  @override
  Future<void> waitForFrames([
    int? minimum,
    DecoderWorkerWaitOptions? options,
  ]) async {
    final min = minimum ?? 1;
    var released = 0;
    while (_pending.isNotEmpty &&
        (_ready.length < min || released < _outputsPerWait) &&
        released < _outputsPerWait) {
      final pending = _pending.removeAt(0);
      late final _FakeManagedFrame frame;
      frame = _FakeManagedFrame(pending, () {
        _open.remove(frame);
        _releasedFrames += 1;
      });
      _open.add(frame);
      _ready.add(frame);
      released += 1;
    }
  }

  @override
  Future<DecoderWorkerMetrics> snapshotMetrics() async {
    final generation = activeGeneration;
    final submittedFrames =
        _pending.where((item) => item.generation == generation).length;
    final leasedFrames =
        _open.where((frame) => frame.generation == generation).length;
    return DecoderWorkerMetrics(
      configureCalls: 1,
      resetCalls: 0,
      flushCalls: 0,
      boundaryFlushCalls: 0,
      acceptedSamples: _acceptedSamples,
      submittedChunks: _acceptedSamples,
      outputFrames: _acceptedSamples - _pending.length,
      deliveredFrames: _acceptedSamples - _pending.length,
      releasedFrames: _releasedFrames,
      staleFrames: 0,
      closedFrames: _releasedFrames,
      pendingSamples: 0,
      submittedFrames: submittedFrames,
      leasedFrames: leasedFrames,
      leasedDecodedBytes: leasedFrames * 128,
      decodeQueueSize: submittedFrames,
      activeGeneration: generation,
      nextSubmissionOrdinal: _acceptedSamples,
      nextOutputOrdinal: _acceptedSamples - _pending.length,
      errors: 0,
      disposed: false,
    );
  }
}

class _FakeManagedFrame implements ManagedDecoderWorkerFrame {
  _FakeManagedFrame(_PendingFakeSample pending, this._release)
      : frame = _FakeVideoFrame(),
        frameId = pending.sample.ordinal + 1,
        generation = pending.generation,
        ordinal = pending.sample.ordinal,
        unitId = pending.sample.unitId,
        unitInstance = pending.sample.unitInstance,
        unitFrame = pending.sample.unitFrame,
        timestamp = pending.sample.timestamp,
        duration = pending.sample.duration;

  @override
  final VideoFrame frame;
  @override
  final int frameId;
  @override
  final int generation;
  @override
  final int ordinal;
  @override
  final String unitId;
  @override
  final int unitInstance;
  @override
  final int unitFrame;
  @override
  final int timestamp;
  @override
  final int duration;
  @override
  final int decodedBytes = 128;
  @override
  int? get outputCallbackMicroseconds => null;

  final void Function() _release;
  bool _closed = false;

  @override
  bool get closed => _closed;

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _release();
  }
}

class _FakeVideoFrame implements VideoFrame {}
