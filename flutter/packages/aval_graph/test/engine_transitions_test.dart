// Ported from packages/graph/test/engine-transitions.test.ts
import 'package:aval_graph/aval_graph.dart';
import 'package:test/test.dart';

void main() {
  group('MotionGraphEngine transition routing', () {
    test('reverses an active resident clip to the adjacent frame on the next tick', () {
      final engine = _animatedEngine(_reversibleGraph());

      final forward = engine.request('hover');
      expect(forward.accepted, true);
      expect(forward.joined, false);
      expect(
        engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(0))).presentation,
        _reversiblePresentation('idle-to-hover', 0, TransitionDirection.forward),
      );
      expect(
        engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(1))).presentation,
        _reversiblePresentation('idle-to-hover', 1, TransitionDirection.forward),
      );

      final inverse = engine.request('idle');
      expect(inverse.accepted, true);
      expect(inverse.joined, false);
      expect(inverse.snapshot.phase, MotionGraphPhase.reversible);
      expect(inverse.snapshot.requestedState, 'idle');
      expect(inverse.snapshot.visualState, 'idle');
      expect(inverse.snapshot.prospectiveState, 'idle');

      final reversed = engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(2)));
      expect(reversed.presentation, _reversiblePresentation('hover-to-idle', 0, TransitionDirection.reverse));
      expect(
        reversed.effects,
        contains(MotionGraphEffectTransitionStart(
          edgeId: 'hover-to-idle',
          from: 'hover',
          to: 'idle',
          sequence: inverse.sequence!,
        )),
      );
    });

    test('previews a reversible tick exactly without advancing its active route', () {
      final engine = _animatedEngine(_reversibleGraph());
      engine.request('hover');
      engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(0)));
      final beforeSnapshot = engine.snapshot();
      final beforeTrace = engine.getTrace();

      final firstPreview = engine.previewTick(MotionGraphTickOptions(contentOrdinal: BigInt.from(1)));
      final secondPreview = engine.previewTick(MotionGraphTickOptions(contentOrdinal: BigInt.from(1)));

      expect(firstPreview, secondPreview);
      expect(
        firstPreview.presentation,
        _reversiblePresentation('idle-to-hover', 1, TransitionDirection.forward),
      );
      expect(engine.snapshot(), beforeSnapshot);
      expect(engine.getTrace(), beforeTrace);
      expect(engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(1))), firstPreview);
    });

    test('reverses an active reverse clip forward to the adjacent frame', () {
      final engine = _animatedEngine(_reversibleGraph());
      engine.request('hover');
      engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(0)));
      engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(1)));
      engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(2)));
      engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(3)));

      engine.request('idle');
      expect(
        engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(4))).presentation,
        _reversiblePresentation('hover-to-idle', 2, TransitionDirection.reverse),
      );
      expect(
        engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(5))).presentation,
        _reversiblePresentation('hover-to-idle', 1, TransitionDirection.reverse),
      );

      final forward = engine.request('hover');
      final adjacent = engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(6)));
      expect(adjacent.presentation, _reversiblePresentation('idle-to-hover', 2, TransitionDirection.forward));
      expect(
        adjacent.effects,
        contains(MotionGraphEffectTransitionStart(
          edgeId: 'idle-to-hover',
          from: 'idle',
          to: 'hover',
          sequence: forward.sequence!,
        )),
      );
    });

    test('cancels a portal-waiting edge when its source state is requested', () {
      final engine = _animatedEngine(_reversibleGraph());
      final pending = engine.request('hover');

      expect(pending.snapshot.phase, MotionGraphPhase.waiting);
      expect(pending.snapshot.pendingEdgeId, 'idle-to-hover');
      expect(pending.snapshot.requestedState, 'hover');

      final cancelled = engine.request('idle');
      expect(cancelled.accepted, true);
      expect(cancelled.joined, false);
      expect(cancelled.snapshot.phase, MotionGraphPhase.stable);
      expect(cancelled.snapshot.pendingEdgeId, isNull);
      expect(cancelled.snapshot.requestedState, 'idle');
      expect(cancelled.snapshot.visualState, 'idle');
      expect(cancelled.snapshot.isTransitioning, false);
      expect(_settleEffects(cancelled), [
        _settle([pending.requestId!], reject: GraphSettlementError.abortError),
        _settle([cancelled.requestId!], resolve: GraphSettlementResolveReason.stableNoop),
      ]);

      final next = engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(0)));
      expect(next.presentation, _bodyFrame('idle', 1));
      expect(_effectTypes(next), isNot(contains(MotionGraphEffectTransitionStart)));
    });

    test('does not clear a mismatched pending route or request on invalid resume', () {
      final engine = _animatedEngine(_reversibleGraph());
      engine.request('hover');
      final waitingSnapshot = engine.snapshot();
      final waitingTrace = engine.getTrace();

      expect(
        () => engine.resumeAnimated(),
        throwsA(isA<MotionGraphError>().having((e) => e.message, 'message', contains('requires phase static'))),
      );
      expect(engine.snapshot(), waitingSnapshot);
      expect(engine.getTrace(), waitingTrace);
      expect(engine.snapshot().phase, MotionGraphPhase.waiting);
      expect(engine.snapshot().requestedState, 'hover');
      expect(engine.snapshot().visualState, 'idle');
      expect(engine.snapshot().pendingEdgeId, 'idle-to-hover');
      expect(engine.snapshot().pendingRequestCount, 1);

      engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(0)));
      final activeSnapshot = engine.snapshot();
      final activeTrace = engine.getTrace();
      expect(
        () => engine.resumeAnimated(),
        throwsA(isA<MotionGraphError>().having((e) => e.message, 'message', contains('requires phase static'))),
      );
      expect(engine.snapshot(), activeSnapshot);
      expect(engine.getTrace(), activeTrace);
      expect(engine.snapshot().phase, MotionGraphPhase.reversible);
      expect(engine.snapshot().activeEdgeId, 'idle-to-hover');
      expect(engine.snapshot().pendingRequestCount, 1);
    });

    test('uses the pending edge\'s inverse event before normal visual-state lookup', () {
      final engine = _animatedEngine(_reversibleGraph());

      final beforeQuery = engine.snapshot();
      final traceBeforeQuery = engine.getTrace();
      expect(engine.canSend('hover.enter'), true);
      expect(engine.canSend('unknown.event'), false);
      expect(engine.snapshot(), beforeQuery);
      expect(engine.getTrace(), traceBeforeQuery);

      expect(engine.send('hover.enter').accepted, true);
      final cancelled = engine.send('hover.leave');

      expect(cancelled.accepted, true);
      expect(cancelled.snapshot.phase, MotionGraphPhase.stable);
      expect(cancelled.snapshot.pendingEdgeId, isNull);
      expect(cancelled.snapshot.requestedState, 'idle');
      expect(cancelled.snapshot.visualState, 'idle');
      expect(cancelled.snapshot.isTransitioning, false);
      expect(
        engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(0))).presentation,
        _bodyFrame('idle', 1),
      );
      expect(
        engine.getTrace().any((r) => r.result.presentation is GraphPresentationReversible),
        false,
      );
    });

    test('lets a source request cancel an event-owned route during preparation', () {
      final engine = MotionGraphEngine();
      engine.install(_reversibleGraph());
      expect(engine.send('hover.enter').accepted, true);

      final source = engine.request('idle');
      expect(source.snapshot.phase, MotionGraphPhase.preparing);
      expect(source.snapshot.requestedState, 'idle');
      expect(source.snapshot.visualState, 'idle');
      expect(source.snapshot.pendingEdgeId, isNull);
      expect(source.snapshot.isTransitioning, false);
      expect(_settleEffects(source), [
        _settle([source.requestId!], resolve: GraphSettlementResolveReason.stableNoop),
      ]);
      expect(engine.beginAnimated().snapshot.phase, MotionGraphPhase.stable);
    });

    test('lets an inverse event cancel a pending route while the intro continues', () {
      final definition = _reversibleGraph();
      final states = definition['states']! as List;
      final initial = states[0]! as Map<String, Object?>;
      final engine = MotionGraphEngine();
      engine.install({
        ...definition,
        'states': [
          {...initial, 'initialUnit': {'unitId': 'idle-intro', 'frameCount': 2}},
          ...states.skip(1),
        ],
      });
      engine.beginAnimated();

      expect(engine.send('hover.enter').accepted, true);
      final cancelled = engine.send('hover.leave');
      expect(cancelled.accepted, true);
      expect(cancelled.snapshot.phase, MotionGraphPhase.intro);
      expect(cancelled.snapshot.requestedState, 'idle');
      expect(cancelled.snapshot.visualState, 'idle');
      expect(cancelled.snapshot.pendingEdgeId, isNull);
      expect(cancelled.snapshot.isTransitioning, false);
      expect(
        engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(0))).presentation,
        const GraphPresentationIntro(state: 'idle', unitId: 'idle-intro', frameIndex: 1),
      );
    });

    test('converges a same-tick mixed burst to its newest valid intent', () {
      final engine = _animatedEngine(_reversibleGraph());

      final first = engine.request('hover');
      final inverseEvent = engine.send('hover.leave');
      final latest = engine.request('hover');

      expect([first.sequence, inverseEvent.sequence, latest.sequence], [1, 2, 3]);
      expect(first.accepted, true);
      expect(inverseEvent.accepted, true);
      expect(latest.accepted, true);
      expect(latest.snapshot.phase, MotionGraphPhase.waiting);
      expect(latest.snapshot.requestedState, 'hover');
      expect(latest.snapshot.prospectiveState, 'hover');
      expect(latest.snapshot.pendingEdgeId, 'idle-to-hover');
      expect(latest.snapshot.inputsSinceTick, 3);

      final tick = engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(0)));
      expect(tick.presentation, _reversiblePresentation('idle-to-hover', 0, TransitionDirection.forward));
      expect(tick.snapshot.phase, MotionGraphPhase.reversible);
      expect(tick.snapshot.requestedState, 'hover');
      expect(tick.snapshot.inputsSinceTick, 0);
    });

    test('joins duplicate requests and supersedes the whole group in request order', () {
      final engine = _animatedEngine(_reversibleGraph(includeIdleError: true));

      final first = engine.request('hover');
      final duplicate = engine.request('hover');
      expect(first.accepted, true);
      expect(first.joined, false);
      expect(first.requestId, 1);
      expect(duplicate.accepted, true);
      expect(duplicate.joined, true);
      expect(duplicate.requestId, 2);
      expect(duplicate.snapshot.pendingRequestCount, 2);

      final replacement = engine.request('error');
      expect(replacement.accepted, true);
      expect(replacement.joined, false);
      expect(replacement.requestId, 3);
      expect(
        _settleEffects(replacement),
        [_settle([first.requestId!, duplicate.requestId!], reject: GraphSettlementError.abortError)],
      );
      expect(replacement.snapshot.phase, MotionGraphPhase.waiting);
      expect(replacement.snapshot.requestedState, 'error');
      expect(replacement.snapshot.prospectiveState, 'error');
      expect(replacement.snapshot.pendingEdgeId, 'idle-to-error');
      expect(replacement.snapshot.pendingRequestCount, 1);
    });

    test('retains a valid reversible follow-on and rejects an invalid route without mutation', () {
      final engine = _animatedEngine(_reversibleGraph(includeFollowOn: true));
      final initial = engine.request('hover');
      engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(0)));
      engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(1)));

      final followOn = engine.request('success');
      expect(followOn.accepted, true);
      expect(followOn.joined, false);
      expect(followOn.snapshot.phase, MotionGraphPhase.reversible);
      expect(followOn.snapshot.requestedState, 'success');
      expect(followOn.snapshot.prospectiveState, 'success');
      expect(followOn.snapshot.activeEdgeId, 'idle-to-hover');
      expect(followOn.snapshot.followOnEdgeId, 'hover-to-success');
      expect(_settleEffects(followOn), [_settle([initial.requestId!], reject: GraphSettlementError.abortError)]);

      final beforeInvalid = followOn.snapshot;
      final invalid = engine.request('error');
      expect(invalid.accepted, false);
      expect(invalid.joined, false);
      expect(_settleEffects(invalid), [_settle([invalid.requestId!], reject: GraphSettlementError.routeError)]);
      expect(invalid.snapshot.phase, beforeInvalid.phase);
      expect(invalid.snapshot.requestedState, beforeInvalid.requestedState);
      expect(invalid.snapshot.prospectiveState, beforeInvalid.prospectiveState);
      expect(invalid.snapshot.activeEdgeId, beforeInvalid.activeEdgeId);
      expect(invalid.snapshot.followOnEdgeId, beforeInvalid.followOnEdgeId);
      expect(invalid.snapshot.pendingRequestCount, beforeInvalid.pendingRequestCount);

      expect(
        engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(2))).presentation,
        _reversiblePresentation('idle-to-hover', 2, TransitionDirection.forward),
      );
      final intermediate = engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(3)));
      expect(intermediate.presentation, _bodyFrame('hover', 0));
      expect(intermediate.snapshot.phase, MotionGraphPhase.waiting);
      expect(intermediate.snapshot.visualState, 'hover');
      expect(intermediate.snapshot.requestedState, 'success');
      expect(intermediate.snapshot.pendingEdgeId, 'hover-to-success');

      final committed = engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(4)));
      expect(committed.presentation, _bodyFrame('success', 0));
      expect(committed.snapshot.phase, MotionGraphPhase.stable);
      expect(committed.snapshot.visualState, 'success');
      expect(committed.snapshot.requestedState, 'success');
      expect(committed.snapshot.isTransitioning, false);
      expect(
        _settleEffects(committed),
        [_settle([followOn.requestId!], resolve: GraphSettlementResolveReason.targetCommitted)],
      );
    });

    test('lets a repeated inverse event cancel a queued follow-on', () {
      final engine = _animatedEngine(_reversibleGraph(includeIdleError: true));
      engine.request('hover');
      engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(0)));
      engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(1)));

      expect(engine.send('hover.leave').accepted, true);
      final followOn = engine.request('error');
      expect(followOn.snapshot.requestedState, 'error');
      expect(followOn.snapshot.activeEdgeId, 'idle-to-hover');
      expect(followOn.snapshot.followOnEdgeId, 'idle-to-error');
      expect(followOn.snapshot.prospectiveState, 'error');

      final reiteratedInverse = engine.send('hover.leave');
      expect(reiteratedInverse.accepted, true);
      expect(reiteratedInverse.snapshot.requestedState, 'idle');
      expect(reiteratedInverse.snapshot.activeEdgeId, 'idle-to-hover');
      expect(reiteratedInverse.snapshot.followOnEdgeId, isNull);
      expect(reiteratedInverse.snapshot.prospectiveState, 'idle');
      expect(
        _settleEffects(reiteratedInverse),
        [_settle([followOn.requestId!], reject: GraphSettlementError.abortError)],
      );
    });

    test('finishes every locked bridge frame before routing its latest valid follow-on', () {
      final engine = _animatedEngine(_lockedFollowOnGraph());
      final loading = engine.request('loading');

      expect(
        engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(0))).presentation,
        _lockedPresentation('idle-to-loading', 0),
      );
      final success = engine.request('success');
      expect(success.accepted, true);
      expect(success.joined, false);
      expect(success.snapshot.phase, MotionGraphPhase.locked);
      expect(success.snapshot.requestedState, 'success');
      expect(success.snapshot.prospectiveState, 'success');
      expect(success.snapshot.activeEdgeId, 'idle-to-loading');
      expect(success.snapshot.followOnEdgeId, 'loading-to-success');
      expect(
        _settleEffects(success),
        [_settle([loading.requestId!], reject: GraphSettlementError.abortError)],
      );

      expect(
        engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(1))).presentation,
        _lockedPresentation('idle-to-loading', 1),
      );
      expect(
        engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(2))).presentation,
        _lockedPresentation('idle-to-loading', 2),
      );

      final intermediate = engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(3)));
      expect(intermediate.presentation, _bodyFrame('loading', 0));
      expect(intermediate.snapshot.phase, MotionGraphPhase.waiting);
      expect(intermediate.snapshot.visualState, 'loading');
      expect(intermediate.snapshot.requestedState, 'success');
      expect(intermediate.snapshot.pendingEdgeId, 'loading-to-success');
      expect(_effectTypes(intermediate), [MotionGraphEffectVisualStateChange, MotionGraphEffectTransitionEnd]);

      final committed = engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(4)));
      expect(committed.presentation, _bodyFrame('success', 0));
      expect(committed.snapshot.phase, MotionGraphPhase.stable);
      expect(committed.snapshot.visualState, 'success');
      expect(committed.snapshot.requestedState, 'success');
      expect(committed.snapshot.isTransitioning, false);
      expect(_effectTypes(committed), [
        MotionGraphEffectTransitionStart,
        MotionGraphEffectVisualStateChange,
        MotionGraphEffectTransitionEnd,
        MotionGraphEffectSettle,
      ]);
      expect(
        _settleEffects(committed),
        [_settle([success.requestId!], resolve: GraphSettlementResolveReason.targetCommitted)],
      );
    });

    test('previews a locked tick exactly without advancing its active route', () {
      final engine = _animatedEngine(_lockedFollowOnGraph());
      engine.request('loading');
      engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(0)));
      final beforeSnapshot = engine.snapshot();
      final beforeTrace = engine.getTrace();

      final firstPreview = engine.previewTick(MotionGraphTickOptions(contentOrdinal: BigInt.from(1)));
      final secondPreview = engine.previewTick(MotionGraphTickOptions(contentOrdinal: BigInt.from(1)));

      expect(firstPreview, secondPreview);
      expect(firstPreview.presentation, _lockedPresentation('idle-to-loading', 1));
      expect(engine.snapshot(), beforeSnapshot);
      expect(engine.getTrace(), beforeTrace);
      expect(engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(1))), firstPreview);
    });
  });
}

MotionGraphEngine _animatedEngine(Map<String, Object?> definition) {
  final engine = MotionGraphEngine();
  engine.install(definition);
  engine.beginAnimated();
  return engine;
}

Map<String, Object?> _reversibleGraph({bool includeFollowOn = false, bool includeIdleError = false}) {
  final states = [_state('idle'), _state('hover')];
  final edges = <Object?>[
    _reversibleEdge('idle-to-hover', 'idle', 'hover', TransitionDirection.forward, 'hover.enter'),
    _reversibleEdge('hover-to-idle', 'hover', 'idle', TransitionDirection.reverse, 'hover.leave',
        reverseOf: 'idle-to-hover'),
  ];

  if (includeFollowOn) {
    states.add(_state('success'));
    states.add(_state('error'));
    edges.add(_cutEdge('hover-to-success', 'hover', 'success'));
  } else if (includeIdleError) {
    states.add(_state('error'));
    edges.add(_cutEdge('idle-to-error', 'idle', 'error'));
  }

  return {'initialState': 'idle', 'states': states, 'edges': edges};
}

Map<String, Object?> _lockedFollowOnGraph() {
  return {
    'initialState': 'idle',
    'states': [_state('idle'), _state('loading'), _state('success')],
    'edges': [
      {
        ..._portalEdge('idle-to-loading', 'idle', 'loading'),
        'transition': {'kind': 'locked', 'unitId': 'loading-bridge', 'frameCount': 3},
      },
      _cutEdge('loading-to-success', 'loading', 'success'),
    ],
  };
}

Map<String, Object?> _state(String id) {
  return {
    'id': id,
    'body': {
      'unitId': '$id-body',
      'kind': 'loop',
      'frameCount': 4,
      'ports': [
        {'id': 'handoff', 'entryFrame': 0, 'portalFrames': const [0, 2]},
      ],
    },
  };
}

Map<String, Object?> _portalEdge(String id, String from, String to) {
  return {
    'id': id,
    'from': from,
    'to': to,
    'start': {'type': 'portal', 'sourcePort': 'handoff', 'targetPort': 'handoff', 'maxWaitFrames': 1},
    'continuity': 'exact-authored',
  };
}

Map<String, Object?> _reversibleEdge(
  String id,
  String from,
  String to,
  TransitionDirection direction,
  String event, {
  String? reverseOf,
}) {
  final transition = <String, Object?>{
    'kind': 'reversible',
    'unitId': 'hover-clip',
    'frameCount': 3,
    'direction': direction.name,
  };
  if (reverseOf != null) transition['reverseOf'] = reverseOf;
  return {
    ..._portalEdge(id, from, to),
    'trigger': {'type': 'event', 'name': event},
    'transition': transition,
    'continuity': reverseOf == null ? 'exact-authored' : 'exact-reverse',
  };
}

Map<String, Object?> _cutEdge(String id, String from, String to) {
  return {
    'id': id,
    'from': from,
    'to': to,
    'start': {'type': 'cut', 'targetPort': 'handoff', 'maxWaitFrames': 1},
    'continuity': 'cut',
  };
}

GraphPresentationReversible _reversiblePresentation(
  String edgeId,
  int frameIndex,
  TransitionDirection direction,
) {
  return GraphPresentationReversible(
    edgeId: edgeId,
    unitId: 'hover-clip',
    frameIndex: frameIndex,
    direction: direction,
  );
}

GraphPresentationLocked _lockedPresentation(String edgeId, int frameIndex) {
  return GraphPresentationLocked(edgeId: edgeId, unitId: 'loading-bridge', frameIndex: frameIndex);
}

GraphPresentationBody _bodyFrame(String state, int frameIndex) =>
    GraphPresentationBody(state: state, unitId: '$state-body', frameIndex: frameIndex);

List<Type> _effectTypes(MotionGraphResult result) => result.effects.map((e) => e.runtimeType).toList();

List<MotionGraphEffectSettle> _settleEffects(MotionGraphResult result) =>
    result.effects.whereType<MotionGraphEffectSettle>().toList();

MotionGraphEffectSettle _settle(
  List<int> requestIds, {
  GraphSettlementResolveReason? resolve,
  GraphSettlementError? reject,
}) {
  final outcome = resolve != null
      ? GraphSettlementResolve(resolve)
      : GraphSettlementReject(reject!);
  return MotionGraphEffectSettle(requestIds: requestIds, outcome: outcome);
}
