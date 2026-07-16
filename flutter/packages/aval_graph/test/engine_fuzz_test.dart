// Ported from packages/graph/test/engine-fuzz.test.ts
//
// The TypeScript original imports a shared `mutationSeeds` helper from
// `tests/mutation/seed-profile.ts`, a repo-wide utility outside the graph
// package used by several packages' fuzz suites to read a committed seed
// profile from `AVL_MUTATION_SEEDS`. This Dart package is self-contained
// (test/*.dart within its own directory), so the same small, dependency-free
// logic is reproduced locally rather than reaching outside the package.
import 'dart:io' show Platform;

import 'package:aval_graph/aval_graph.dart';
import 'package:aval_graph/src/validate.dart';
import 'package:test/test.dart';

const int _generatedTicks = 2500;
const int _drainTicks = 80;

void main() {
  final seeds = _mutationSeeds(const [1, 0x5eedc0de, 0xc0ffee, 0xffffffff]);

  group('MotionGraphEngine seeded properties', () {
    for (final seed in seeds) {
      test('replays seed 0x${seed.toRadixString(16)} deterministically', () {
        final tape = _createTape(seed);
        final first = _replayTape(tape, seed);
        final second = _replayTape(tape, seed);

        expect(second.results, first.results);
        expect(second.finalSnapshot, first.finalSnapshot);
        expect(second.trace, first.trace);

        expect(first.finalSnapshot.phase, MotionGraphPhase.stable);
        expect(first.finalSnapshot.visualState, first.finalSnapshot.requestedState);
        expect(first.finalSnapshot.pendingRequestCount, 0);
        expect(first.issuedRequestIds, isNotEmpty);
        expect(first.settledRequestIds, first.issuedRequestIds);

        expect(first.trace, hasLength(GraphLimits.maxTraceRecords));
        expect(
          first.trace.first.index,
          first.results.length - GraphLimits.maxTraceRecords + 1,
        );
        expect(first.trace.last.index, first.results.length);
      });
    }
  });
}

sealed class _TapeOperation {
  const _TapeOperation();
}

class _RequestOp extends _TapeOperation {
  const _RequestOp(this.target);
  final String target;

  @override
  String toString() => 'request($target)';
}

class _SendOp extends _TapeOperation {
  const _SendOp(this.event);
  final String event;

  @override
  String toString() => 'send($event)';
}

class _TickOp extends _TapeOperation {
  const _TickOp(this.routeReady);
  final bool routeReady;

  @override
  String toString() => 'tick(routeReady: $routeReady)';
}

class _Replay {
  const _Replay({
    required this.results,
    required this.finalSnapshot,
    required this.trace,
    required this.issuedRequestIds,
    required this.settledRequestIds,
  });

  final List<MotionGraphResult> results;
  final MotionGraphSnapshot finalSnapshot;
  final List<MotionGraphTraceRecord> trace;
  final Set<int> issuedRequestIds;
  final Set<int> settledRequestIds;
}

final ValidatedGraphIndexes _fuzzIndexes =
    getValidatedGraphIndexes(validateMotionGraphDefinition(_fuzzGraph()));

_Replay _replayTape(List<_TapeOperation> tape, int seed) {
  final engine = MotionGraphEngine();
  final results = <MotionGraphResult>[];
  final issuedRequestIds = <int>{};
  final settledRequestIds = <int>{};
  var nextRequestId = 1;
  var nextContentOrdinal = BigInt.zero;
  var inputsSinceTick = 0;

  final installed = engine.install(_fuzzGraph());
  // Installation establishes the initial visual state; it is not a runtime
  // visual-state transition and therefore has no visualstatechange effect.
  _assertResultProperties(installed, installed.snapshot, seed, -2);
  results.add(installed);
  var previous = installed.snapshot;

  final animated = engine.beginAnimated();
  _assertResultProperties(animated, previous, seed, -1);
  results.add(animated);
  previous = animated.snapshot;

  final reduced = engine.recoverStatic('seeded-resume-model');
  _assertResultProperties(reduced, previous, seed, -0.75);
  results.add(reduced);
  previous = reduced.snapshot;

  final resumed = engine.resumeAnimated();
  _assertResultProperties(resumed, previous, seed, -0.5);
  final resumedPresentation = resumed.presentation;
  _invariant(
    resumed.operation == MotionGraphOperation.resumeAnimated &&
        resumed.effects.length == 1 &&
        resumed.effects[0] is MotionGraphEffectReadinessChange &&
        resumedPresentation is GraphPresentationIntro &&
        resumedPresentation.state == resumed.snapshot.visualState &&
        resumedPresentation.frameIndex == 0 &&
        resumed.snapshot.initialUnitPending,
    seed,
    -0.5,
    'static resume did not restart the unfinished intro exactly',
  );
  results.add(resumed);
  previous = resumed.snapshot;

  for (var index = 0; index < tape.length; index += 1) {
    final operation = tape[index];
    final MotionGraphResult result;

    if (operation is _RequestOp) {
      inputsSinceTick += 1;
      result = engine.request(operation.target);
      _invariant(
        result.requestId == nextRequestId,
        seed,
        index,
        'request ID ${result.requestId} is not $nextRequestId',
      );
      issuedRequestIds.add(nextRequestId);
      nextRequestId += 1;

      if (inputsSinceTick > GraphLimits.maxInputsPerTick) {
        _invariant(
          result.accepted == false,
          seed,
          index,
          'request beyond the per-tick input cap was accepted',
        );
        _invariant(
          result.effects.any((effect) =>
              effect is MotionGraphEffectSettle &&
              effect.outcome is GraphSettlementReject &&
              (effect.outcome as GraphSettlementReject).error ==
                  GraphSettlementError.inputOverflowError),
          seed,
          index,
          'overflowed request did not receive InputOverflowError',
        );
      }
    } else if (operation is _SendOp) {
      inputsSinceTick += 1;
      result = engine.send(operation.event);
      if (inputsSinceTick > GraphLimits.maxInputsPerTick) {
        _invariant(
          result.accepted == false,
          seed,
          index,
          'event beyond the per-tick input cap was accepted',
        );
      }
    } else {
      final tickOp = operation as _TickOp;
      try {
        result = engine.tick(
          MotionGraphTickOptions(contentOrdinal: nextContentOrdinal, routeReady: tickOp.routeReady),
        );
      } catch (error) {
        final start = index - 8 < 0 ? 0 : index - 8;
        final recentOperations = tape.sublist(start, index + 1);
        final recentStart = results.length > 10 ? results.length - 10 : 0;
        final recentResults = results.sublist(recentStart).map(_summarizeResult).toList();
        throw StateError(
          'seed=0x${seed.toRadixString(16)} operation=$index recentOperations=$recentOperations '
          'recentResults=$recentResults (cause: $error)',
        );
      }
      nextContentOrdinal += BigInt.one;
    }

    _assertResultProperties(result, previous, seed, index);
    _collectSettlements(result.effects, issuedRequestIds, settledRequestIds, seed, index);

    final expectedInputs = operation is _TickOp
        ? 0
        : (inputsSinceTick < GraphLimits.maxInputsPerTick ? inputsSinceTick : GraphLimits.maxInputsPerTick);
    _invariant(
      result.snapshot.inputsSinceTick == expectedInputs,
      seed,
      index,
      'inputsSinceTick is ${result.snapshot.inputsSinceTick}, expected $expectedInputs',
    );

    if (operation is _TickOp) {
      inputsSinceTick = 0;
      _invariant(
        result.snapshot.contentOrdinal == nextContentOrdinal - BigInt.one,
        seed,
        index,
        'tick did not consume exactly one content ordinal',
      );
    } else {
      _invariant(
        result.presentation == previous.presentation,
        seed,
        index,
        'an input operation changed the presented frame',
      );
    }

    _invariant(
      result.snapshot.pendingRequestCount == issuedRequestIds.length - settledRequestIds.length,
      seed,
      index,
      'pending request count ${result.snapshot.pendingRequestCount} diverged from unsettled IDs '
      'after operation $operation',
    );

    results.add(result);
    previous = result.snapshot;
  }

  return _Replay(
    results: List.unmodifiable(results),
    finalSnapshot: engine.snapshot(),
    trace: engine.getTrace(),
    issuedRequestIds: issuedRequestIds,
    settledRequestIds: settledRequestIds,
  );
}

Map<String, Object?> _summarizeResult(MotionGraphResult result) {
  return {
    'operation': result.operation.name,
    'accepted': result.accepted,
    'joined': result.joined,
    'requestId': result.requestId,
    'effects': result.effects.map((e) => e.runtimeType.toString()).toList(),
    'phase': result.snapshot.phase.name,
    'requested': result.snapshot.requestedState,
    'visual': result.snapshot.visualState,
    'prospective': result.snapshot.prospectiveState,
    'pending': result.snapshot.pendingRequestCount,
    'pendingEdge': result.snapshot.pendingEdgeId,
    'activeEdge': result.snapshot.activeEdgeId,
    'followOn': result.snapshot.followOnEdgeId,
  };
}

void _assertResultProperties(
  MotionGraphResult result,
  MotionGraphSnapshot previous,
  int seed,
  num operationIndex,
) {
  // The TypeScript original also asserts `Object.isFrozen(...)` on the
  // result, snapshot, effects, and presentation. Every corresponding Dart
  // type here is immutable by construction (final fields, no setters), so
  // there is no runtime "frozen" check to make.
  _invariant(
    result.presentation == result.snapshot.presentation,
    seed,
    operationIndex,
    'result and snapshot expose different presentations',
  );

  final presentation = result.presentation;
  if (presentation != null) {
    _assertPresentationBounds(presentation, seed, operationIndex);
  }

  final visualEffects = result.effects.whereType<MotionGraphEffectVisualStateChange>().toList();
  final visualChanged = previous.visualState != result.snapshot.visualState;
  _invariant(
    visualEffects.length == (visualChanged ? 1 : 0),
    seed,
    operationIndex,
    'visual state change does not match its effect count',
  );

  if (visualChanged) {
    final effect = visualEffects[0];
    _invariant(
      effect.from == previous.visualState && effect.to == result.snapshot.visualState,
      seed,
      operationIndex,
      'visualstatechange effect has inconsistent endpoints',
    );
    _invariant(
      _isCommittedPresentation(result.presentation, result.snapshot.visualState),
      seed,
      operationIndex,
      'visual state changed without presenting the target entry',
    );
  }

  String? stableState;
  if (presentation is GraphPresentationBody) {
    stableState = presentation.state;
  } else if (presentation is GraphPresentationIntro) {
    stableState = presentation.state;
  } else if (presentation is GraphPresentationStatic) {
    stableState = presentation.state;
  }
  if (stableState != null) {
    _invariant(
      stableState == result.snapshot.visualState,
      seed,
      operationIndex,
      'stable presentation does not represent visualState',
    );
  }

  for (final effect in result.effects.whereType<MotionGraphEffectTransitionEnd>()) {
    _invariant(
      effect.to == result.snapshot.visualState &&
          _isCommittedPresentation(result.presentation, effect.to),
      seed,
      operationIndex,
      'transition ended without its target entry presentation',
    );
  }
}

void _assertPresentationBounds(GraphPresentation presentation, int seed, num operationIndex) {
  if (presentation is GraphPresentationStatic) {
    final state = _fuzzIndexes.statesById[presentation.state];
    _invariant(state != null, seed, operationIndex, 'static presentation references an unknown state');
    return;
  }

  if (presentation is GraphPresentationIntro) {
    final initial = _fuzzIndexes.statesById[presentation.state]?.initialUnit;
    _invariant(
      initial != null &&
          initial.unitId == presentation.unitId &&
          presentation.frameIndex >= 0 &&
          presentation.frameIndex < initial.frameCount,
      seed,
      operationIndex,
      'intro presentation is outside its unit',
    );
    return;
  }

  if (presentation is GraphPresentationBody) {
    final body = _fuzzIndexes.statesById[presentation.state]?.body;
    _invariant(
      body != null &&
          body.unitId == presentation.unitId &&
          presentation.frameIndex >= 0 &&
          presentation.frameIndex < body.frameCount,
      seed,
      operationIndex,
      'body presentation is outside its unit',
    );
    return;
  }

  if (presentation is GraphPresentationLocked) {
    final transition = _fuzzIndexes.edgesById[presentation.edgeId]?.transition;
    _invariant(
      transition is GraphTransitionLocked &&
          transition.unitId == presentation.unitId &&
          presentation.frameIndex >= 0 &&
          presentation.frameIndex < transition.frameCount,
      seed,
      operationIndex,
      'transition presentation is outside its unit',
    );
    return;
  }

  final reversible = presentation as GraphPresentationReversible;
  final transition = _fuzzIndexes.edgesById[reversible.edgeId]?.transition;
  _invariant(
    transition is GraphTransitionReversible &&
        transition.unitId == reversible.unitId &&
        reversible.frameIndex >= 0 &&
        reversible.frameIndex < transition.frameCount,
    seed,
    operationIndex,
    'transition presentation is outside its unit',
  );
  _invariant(
    transition is GraphTransitionReversible && transition.direction == reversible.direction,
    seed,
    operationIndex,
    'reversible presentation has the wrong direction',
  );
}

void _collectSettlements(
  List<MotionGraphEffect> effects,
  Set<int> issued,
  Set<int> settled,
  int seed,
  num operationIndex,
) {
  for (final effect in effects) {
    if (effect is! MotionGraphEffectSettle) continue;
    final unique = effect.requestIds.toSet();
    _invariant(
      unique.length == effect.requestIds.length,
      seed,
      operationIndex,
      'one settlement contains a duplicate request ID',
    );
    for (var index = 1; index < effect.requestIds.length; index += 1) {
      _invariant(
        effect.requestIds[index - 1] < effect.requestIds[index],
        seed,
        operationIndex,
        'settlement request IDs are not in request order',
      );
    }
    for (final requestId in effect.requestIds) {
      _invariant(issued.contains(requestId), seed, operationIndex, 'settled unknown request $requestId');
      _invariant(
        !settled.contains(requestId),
        seed,
        operationIndex,
        'request $requestId settled more than once',
      );
      settled.add(requestId);
    }
  }
}

bool _isCommittedPresentation(GraphPresentation? presentation, String? target) {
  if (presentation is GraphPresentationStatic) return presentation.state == target;
  return presentation is GraphPresentationBody &&
      presentation.state == target &&
      presentation.frameIndex == 0;
}

List<_TapeOperation> _createTape(int seed) {
  final random = _mulberry32(seed);
  final tape = <_TapeOperation>[];
  const targets = ['idle', 'hovered', 'success', 'missing'];
  const events = ['hover.on', 'hover.off', 'complete', 'reset', 'unknown'];

  for (var tick = 0; tick < _generatedTicks; tick += 1) {
    final inputCount = tick % 211 == 0 ? 40 : (random() * 5).floor();
    for (var input = 0; input < inputCount; input += 1) {
      if (random() < 0.72) {
        tape.add(_RequestOp(targets[(random() * targets.length).floor()]));
      } else {
        tape.add(_SendOp(events[(random() * events.length).floor()]));
      }
    }
    tape.add(_TickOp(tick % 7 == 0 || random() >= 0.2));
  }

  for (var tick = 0; tick < _drainTicks; tick += 1) {
    tape.add(const _TickOp(true));
  }
  return List.unmodifiable(tape);
}

/// Deterministic PRNG (mulberry32), used only to generate this test's
/// pseudo-random operation tape. Bit-for-bit parity with the TypeScript
/// original's JS-`number`-based implementation is not required: nothing
/// compares a Dart-generated tape against a JS-generated one, only against
/// itself (replayed twice), so this only needs to be internally
/// deterministic, which 64-bit Dart `int` arithmetic (masked to 32 bits at
/// each step) provides.
double Function() _mulberry32(int seed) {
  var state = seed & 0xFFFFFFFF;
  return () {
    state = (state + 0x6d2b79f5) & 0xFFFFFFFF;
    var value = state;
    value = ((value ^ (value >> 15)) * (value | 1)) & 0xFFFFFFFF;
    value = (value + (((value ^ (value >> 7)) * (value | 61)) & 0xFFFFFFFF)) & 0xFFFFFFFF;
    return ((value ^ (value >> 14)) & 0xFFFFFFFF) / 4294967296.0;
  };
}

void _invariant(bool condition, int seed, num operationIndex, String message) {
  if (!condition) {
    throw StateError('seed=0x${seed.toRadixString(16)} operation=$operationIndex: $message');
  }
}

const int _maxProfileSeeds = 64;
const int _uint32Max = 0xffffffff;

/// Resolves the committed mutation profile, mirroring
/// `tests/mutation/seed-profile.ts`'s `mutationSeeds` (read in full earlier
/// this session): individual fuzz files use their historical seeds by
/// default, but a `AVL_MUTATION_SEEDS` environment variable (as set by a
/// matrix runner) overrides them.
List<int> _mutationSeeds(List<int> fallback) {
  final encoded = Platform.environment['AVL_MUTATION_SEEDS'];
  if (encoded == null) return _freezeValidatedSeeds(fallback, 'fallback');
  if (encoded.isEmpty || encoded.length > 1024) {
    throw StateError('AVL_MUTATION_SEEDS has an invalid encoded length');
  }
  final fields = encoded.split(',');
  if (fields.length > _maxProfileSeeds) {
    throw StateError('AVL_MUTATION_SEEDS exceeds $_maxProfileSeeds seeds');
  }
  final seeds = <int>[];
  for (final field in fields) {
    if (!RegExp(r'^(?:0|[1-9][0-9]*)$').hasMatch(field)) {
      throw StateError('AVL_MUTATION_SEEDS contains a non-canonical uint32: $field');
    }
    seeds.add(int.parse(field));
  }
  return _freezeValidatedSeeds(seeds, 'AVL_MUTATION_SEEDS');
}

List<int> _freezeValidatedSeeds(List<int> seeds, String source) {
  if (seeds.isEmpty || seeds.length > _maxProfileSeeds) {
    throw StateError('$source must contain 1 through $_maxProfileSeeds seeds');
  }
  final unique = <int>{};
  for (final seed in seeds) {
    if (seed < 0 || seed > _uint32Max) {
      throw StateError('$source contains an invalid uint32 seed: $seed');
    }
    if (!unique.add(seed)) {
      throw StateError('$source contains duplicate seed $seed');
    }
  }
  return List.unmodifiable(seeds);
}

Map<String, Object?> _fuzzGraph() {
  return {
    'initialState': 'idle',
    'states': [
      {
        'id': 'idle',
        'initialUnit': {'unitId': 'intro-unit', 'frameCount': 2},
        'body': {
          'unitId': 'idle-body',
          'kind': 'loop',
          'frameCount': 5,
          'ports': [
            {'id': 'main', 'entryFrame': 0, 'portalFrames': const [1, 4]},
          ],
        },
      },
      {
        'id': 'hovered',
        'body': {
          'unitId': 'hovered-body',
          'kind': 'loop',
          'frameCount': 4,
          'ports': [
            {'id': 'main', 'entryFrame': 0, 'portalFrames': const [0, 2]},
          ],
        },
      },
      {
        'id': 'success',
        'body': {
          'unitId': 'success-body',
          'kind': 'finite',
          'frameCount': 3,
          'ports': [
            {'id': 'main', 'entryFrame': 0, 'portalFrames': const [2]},
          ],
        },
      },
    ],
    'edges': [
      {
        'id': 'idle-hovered',
        'from': 'idle',
        'to': 'hovered',
        'trigger': {'type': 'event', 'name': 'hover.on'},
        'start': {'type': 'portal', 'sourcePort': 'main', 'targetPort': 'main', 'maxWaitFrames': 5},
        'transition': {
          'kind': 'reversible',
          'unitId': 'hover-shift',
          'frameCount': 4,
          'direction': 'forward',
        },
        'continuity': 'exact-authored',
      },
      {
        'id': 'hovered-idle',
        'from': 'hovered',
        'to': 'idle',
        'trigger': {'type': 'event', 'name': 'hover.off'},
        'start': {'type': 'portal', 'sourcePort': 'main', 'targetPort': 'main', 'maxWaitFrames': 4},
        'transition': {
          'kind': 'reversible',
          'unitId': 'hover-shift',
          'frameCount': 4,
          'direction': 'reverse',
          'reverseOf': 'idle-hovered',
        },
        'continuity': 'exact-reverse',
      },
      {
        'id': 'idle-success',
        'from': 'idle',
        'to': 'success',
        'trigger': {'type': 'event', 'name': 'complete'},
        'start': {'type': 'portal', 'sourcePort': 'main', 'targetPort': 'main', 'maxWaitFrames': 5},
        'transition': {'kind': 'locked', 'unitId': 'idle-success-bridge', 'frameCount': 2},
        'continuity': 'exact-authored',
      },
      {
        'id': 'hovered-success',
        'from': 'hovered',
        'to': 'success',
        'trigger': {'type': 'event', 'name': 'complete'},
        'start': {'type': 'portal', 'sourcePort': 'main', 'targetPort': 'main', 'maxWaitFrames': 4},
        'transition': {'kind': 'locked', 'unitId': 'hovered-success-bridge', 'frameCount': 3},
        'continuity': 'exact-authored',
      },
      {
        'id': 'success-idle',
        'from': 'success',
        'to': 'idle',
        'trigger': {'type': 'event', 'name': 'reset'},
        'start': {'type': 'finish', 'targetPort': 'main', 'maxWaitFrames': 2},
        'transition': {'kind': 'locked', 'unitId': 'success-idle-bridge', 'frameCount': 2},
        'continuity': 'exact-authored',
      },
      {
        'id': 'success-hovered',
        'from': 'success',
        'to': 'hovered',
        'trigger': {'type': 'event', 'name': 'hover.on'},
        'start': {'type': 'finish', 'targetPort': 'main', 'maxWaitFrames': 2},
        'transition': {'kind': 'locked', 'unitId': 'success-hovered-bridge', 'frameCount': 1},
        'continuity': 'exact-authored',
      },
    ],
  };
}
