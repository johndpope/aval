// Ported from packages/graph/test/engine-golden.test.ts
import 'package:aval_graph/aval_graph.dart';
import 'package:test/test.dart';

void main() {
  group('MotionGraphEngine golden lifecycle traces', () {
    test('installs the initial static frame and resolves a stable no-op without state events', () {
      final engine = MotionGraphEngine();
      final install = engine.install(_graph());

      expect(install.presentation, const GraphPresentationStatic(state: 'idle'));
      expect(install.effects, [_readiness(MotionGraphReadiness.unready, MotionGraphReadiness.preparing)]);
      expect(install.snapshot.readiness, MotionGraphReadiness.preparing);
      expect(install.snapshot.phase, MotionGraphPhase.preparing);
      expect(install.snapshot.requestedState, 'idle');
      expect(install.snapshot.visualState, 'idle');
      expect(install.snapshot.isTransitioning, false);
      expect(install.snapshot.contentOrdinal, isNull);

      final animated = engine.beginAnimated();
      expect(animated.presentation, _bodyFrame('idle', 0));
      expect(animated.effects, [_readiness(MotionGraphReadiness.preparing, MotionGraphReadiness.animated)]);
      expect(animated.snapshot.readiness, MotionGraphReadiness.animated);
      expect(animated.snapshot.phase, MotionGraphPhase.stable);
      expect(animated.snapshot.requestedState, 'idle');
      expect(animated.snapshot.visualState, 'idle');
      expect(animated.snapshot.isTransitioning, false);

      final noop = engine.request('idle');
      expect(noop.accepted, true);
      expect(noop.joined, false);
      expect(noop.sequence, 1);
      expect(noop.requestId, 1);
      expect(noop.presentation, _bodyFrame('idle', 0));
      expect(noop.effects, [
        _settle([1], const GraphSettlementResolve(GraphSettlementResolveReason.stableNoop)),
      ]);
      expect(noop.snapshot.phase, MotionGraphPhase.stable);
      expect(noop.snapshot.requestedState, 'idle');
      expect(noop.snapshot.visualState, 'idle');
      expect(noop.snapshot.isTransitioning, false);
      expect(noop.snapshot.pendingRequestCount, 0);
    });

    test('rejects a request before metadata with one settlement and no presentation', () {
      final engine = MotionGraphEngine();
      final result = engine.request('hover');

      expect(result.accepted, false);
      expect(result.joined, false);
      expect(result.sequence, 1);
      expect(result.requestId, 1);
      expect(result.presentation, isNull);
      expect(result.effects, [
        _settle([1], const GraphSettlementReject(GraphSettlementError.notReadyError)),
      ]);
      expect(result.snapshot.readiness, MotionGraphReadiness.unready);
      expect(result.snapshot.phase, MotionGraphPhase.unready);
      expect(result.snapshot.requestedState, isNull);
      expect(result.snapshot.visualState, isNull);
      expect(result.snapshot.isTransitioning, false);
    });

    test('uses a later loop portal when the first portal is not route-ready', () {
      final engine = _animatedEngine(_graph(sourceKind: 'loop', sourcePortals: const [1, 3], startType: 'portal', startMaxWaitFrames: 1));

      final request = engine.request('hover');
      expect(request.presentation, _bodyFrame('idle', 0));
      expect(request.effects, [_requested('idle', 'hover', 1)]);
      expect(request.snapshot.phase, MotionGraphPhase.waiting);
      expect(request.snapshot.requestedState, 'hover');
      expect(request.snapshot.visualState, 'idle');
      expect(request.snapshot.prospectiveState, 'hover');
      expect(request.snapshot.pendingEdgeId, 'idle-to-hover');
      expect(request.snapshot.activeEdgeId, isNull);
      expect(request.snapshot.isTransitioning, true);
      expect(request.snapshot.pendingRequestCount, 1);

      final atFirstPortal = engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(0)));
      expect(atFirstPortal.presentation, _bodyFrame('idle', 1));
      expect(atFirstPortal.effects, isEmpty);

      final skipFirstPortal = engine.tick(
        MotionGraphTickOptions(contentOrdinal: BigInt.from(1), routeReady: false),
      );
      expect(skipFirstPortal.presentation, _bodyFrame('idle', 2));
      expect(skipFirstPortal.effects, isEmpty);

      final atLaterPortal = engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(2)));
      expect(atLaterPortal.presentation, _bodyFrame('idle', 3));
      expect(atLaterPortal.effects, isEmpty);

      final commit = engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(3)));
      expect(commit.presentation, _bodyFrame('hover', 0));
      expect(commit.effects, [
        _transitionStart('idle-to-hover', 'idle', 'hover', 1),
        _visual('idle', 'hover'),
        _transitionEnd('idle-to-hover', 'idle', 'hover'),
        _settle([1], const GraphSettlementResolve(GraphSettlementResolveReason.targetCommitted)),
      ]);
      expect(commit.snapshot.phase, MotionGraphPhase.stable);
      expect(commit.snapshot.requestedState, 'hover');
      expect(commit.snapshot.visualState, 'hover');
      expect(commit.snapshot.prospectiveState, 'hover');
      expect(commit.snapshot.pendingEdgeId, isNull);
      expect(commit.snapshot.activeEdgeId, isNull);
      expect(commit.snapshot.isTransitioning, false);
      expect(commit.snapshot.routeOperationsLastTick, 1);
      expect(commit.snapshot.pendingRequestCount, 0);
    });

    test('commits a transitionless portal directly from the displayed portal to target frame zero', () {
      final engine = _animatedEngine(_graph());
      engine.request('hover');

      final result = engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(0)));
      expect(result.presentation, _bodyFrame('hover', 0));
      expect(result.effects, [
        _transitionStart('idle-to-hover', 'idle', 'hover', 1),
        _visual('idle', 'hover'),
        _transitionEnd('idle-to-hover', 'idle', 'hover'),
        _settle([1], const GraphSettlementResolve(GraphSettlementResolveReason.targetCommitted)),
      ]);
    });

    test('commits a cut on the next tick even when routeReady is false', () {
      final engine = _animatedEngine(_graph(startType: 'cut', startMaxWaitFrames: 1));
      engine.request('hover');

      final result = engine.tick(
        MotionGraphTickOptions(contentOrdinal: BigInt.from(0), routeReady: false),
      );
      expect(result.presentation, _bodyFrame('hover', 0));
      expect(result.effects, [
        _transitionStart('idle-to-hover', 'idle', 'hover', 1),
        _visual('idle', 'hover'),
        _transitionEnd('idle-to-hover', 'idle', 'hover'),
        _settle([1], const GraphSettlementResolve(GraphSettlementResolveReason.targetCommitted)),
      ]);
      expect(result.snapshot.routeOperationsLastTick, 1);
    });

    test('searches finite portals forward, never wraps, and holds the final portal until ready', () {
      final engine = _animatedEngine(_graph(sourceKind: 'finite', sourcePortals: const [1, 3], startType: 'portal', startMaxWaitFrames: 1));
      engine.request('hover');

      expect(
        engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(0))).presentation,
        _bodyFrame('idle', 1),
      );
      expect(
        engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(1), routeReady: false)).presentation,
        _bodyFrame('idle', 2),
      );
      expect(
        engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(2))).presentation,
        _bodyFrame('idle', 3),
      );

      final held = engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(3), routeReady: false));
      expect(held.presentation, _bodyFrame('idle', 3));
      expect(held.effects, isEmpty);
      expect(held.snapshot.phase, MotionGraphPhase.waiting);
      expect(held.snapshot.visualState, 'idle');
      expect(held.snapshot.requestedState, 'hover');
      expect(held.snapshot.isTransitioning, true);

      final commit = engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(4)));
      expect(commit.presentation, _bodyFrame('hover', 0));
      expect(commit.effects, [
        _transitionStart('idle-to-hover', 'idle', 'hover', 1),
        _visual('idle', 'hover'),
        _transitionEnd('idle-to-hover', 'idle', 'hover'),
        _settle([1], const GraphSettlementResolve(GraphSettlementResolveReason.targetCommitted)),
      ]);
    });

    test('finishes a finite body exactly once and waits at its held final frame', () {
      final engine = _animatedEngine(_graph(sourceKind: 'finite', sourcePortals: const [0, 3], startType: 'finish', startMaxWaitFrames: 3));
      engine.request('hover');

      for (var ordinal = 0; ordinal < 3; ordinal += 1) {
        final tick = engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(ordinal)));
        expect(tick.presentation, _bodyFrame('idle', ordinal + 1));
        expect(tick.effects, isEmpty);
      }
      final held = engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(3), routeReady: false));
      expect(held.presentation, _bodyFrame('idle', 3));
      expect(held.effects, isEmpty);

      final commit = engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(4)));
      expect(commit.presentation, _bodyFrame('hover', 0));
      expect(commit.effects, [
        _transitionStart('idle-to-hover', 'idle', 'hover', 1),
        _visual('idle', 'hover'),
        _transitionEnd('idle-to-hover', 'idle', 'hover'),
        _settle([1], const GraphSettlementResolve(GraphSettlementResolveReason.targetCommitted)),
      ]);
    });

    test('runs an explicit completion cut even when route readiness is false', () {
      final definition = _graph(sourceKind: 'held', sourcePortals: const [0], startType: 'cut', startMaxWaitFrames: 1);
      final edges = definition['edges']! as List;
      final baseEdge = edges[0]! as Map<String, Object?>;
      final engine = _animatedEngine({
        ...definition,
        'edges': [
          {...baseEdge, 'trigger': {'type': 'completion'}},
        ],
      });

      final completed = engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(0), routeReady: false));
      expect(completed.presentation, _bodyFrame('hover', 0));
      expect(completed.effects, [
        _requested('idle', 'hover', 1),
        _transitionStart('idle-to-hover', 'idle', 'hover', 1),
        _visual('idle', 'hover'),
        _transitionEnd('idle-to-hover', 'idle', 'hover'),
      ]);
      expect(completed.snapshot.phase, MotionGraphPhase.stable);
      expect(completed.snapshot.requestedState, 'hover');
      expect(completed.snapshot.visualState, 'hover');
      expect(completed.snapshot.routeOperationsLastTick, 1);
    });

    test('previews a completion-triggered tick exactly without committing it', () {
      final definition = _graph(sourceKind: 'held', sourcePortals: const [0], startType: 'cut', startMaxWaitFrames: 1);
      final edges = definition['edges']! as List;
      final baseEdge = edges[0]! as Map<String, Object?>;
      final engine = _animatedEngine({
        ...definition,
        'edges': [
          {...baseEdge, 'trigger': {'type': 'completion'}},
        ],
      });
      final beforeSnapshot = engine.snapshot();
      final beforeTrace = engine.getTrace();

      final preview = engine.previewTick(
        MotionGraphTickOptions(contentOrdinal: BigInt.from(0), routeReady: false),
      );

      expect(preview.snapshot.phase, MotionGraphPhase.stable);
      expect(preview.snapshot.visualState, 'hover');
      expect(preview.snapshot.requestedState, 'hover');
      expect(engine.snapshot(), beforeSnapshot);
      expect(engine.getTrace(), beforeTrace);
      expect(
        engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(0), routeReady: false)),
        preview,
      );
    });

    test('previews stable ticks exactly without advancing the graph journal', () {
      final engine = _animatedEngine(_graph());
      final beforeSnapshot = engine.snapshot();
      final beforeTrace = engine.getTrace();

      final preview = engine.previewTick(MotionGraphTickOptions(contentOrdinal: BigInt.from(0)));

      expect(preview.snapshot.phase, MotionGraphPhase.stable);
      expect(preview.snapshot.visualState, 'idle');
      expect(preview.snapshot.contentOrdinal, BigInt.from(0));
      expect(engine.snapshot(), beforeSnapshot);
      expect(engine.getTrace(), beforeTrace);
      expect(engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(0))), preview);
    });

    test('restores pending requests, counters, routes, and trace across repeated previews', () {
      final engine = _animatedEngine(_graph());
      final first = engine.request('hover');
      final duplicate = engine.request('hover');
      final beforeSnapshot = engine.snapshot();
      final beforeTrace = engine.getTrace();

      final firstPreview = engine.previewTick(MotionGraphTickOptions(contentOrdinal: BigInt.from(0)));
      final secondPreview = engine.previewTick(MotionGraphTickOptions(contentOrdinal: BigInt.from(0)));

      expect(firstPreview, secondPreview);
      expect(
        firstPreview.effects,
        contains(_settle(
          [first.requestId!, duplicate.requestId!],
          const GraphSettlementResolve(GraphSettlementResolveReason.targetCommitted),
        )),
      );
      expect(engine.snapshot(), beforeSnapshot);
      expect(engine.snapshot().phase, MotionGraphPhase.waiting);
      expect(engine.snapshot().pendingEdgeId, 'idle-to-hover');
      expect(engine.snapshot().pendingRequestCount, 2);
      expect(engine.snapshot().inputSequence, 2);
      expect(engine.snapshot().inputsSinceTick, 2);
      expect(engine.snapshot().contentOrdinal, isNull);
      expect(engine.getTrace(), beforeTrace);

      expect(engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(0))), firstPreview);
      expect(engine.snapshot().inputsSinceTick, 0);
      final third = engine.request('hover');
      expect(third.requestId, 3);
      expect(third.sequence, 3);
    });

    test('restores the graph when preview evaluation throws after tick admission', () {
      final engine = _animatedEngine(_graph());
      engine.request('hover');
      final beforeSnapshot = engine.snapshot();
      final beforeTrace = engine.getTrace();

      // Unlike the TypeScript original (which simulates a throwing
      // `routeReady` getter — a JS accessor-property quirk with no Dart
      // analog), this exercises the same "previewTick must roll back even
      // when tick() throws deep inside its own pipeline" invariant via a
      // genuinely non-consecutive content ordinal, which throws from
      // `OperationJournal.beginTick` partway through `tick()`.
      expect(
        () => engine.previewTick(MotionGraphTickOptions(contentOrdinal: BigInt.from(5))),
        throwsA(isA<MotionGraphError>()),
      );
      expect(engine.snapshot(), beforeSnapshot);
      expect(engine.getTrace(), beforeTrace);
      final result = engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(0)));
      expect(result.snapshot.phase, MotionGraphPhase.stable);
      expect(result.snapshot.contentOrdinal, BigInt.from(0));
    });

    test('does not invent an implicit completion route for a finite body', () {
      final engine = _animatedEngine(_graph(sourceKind: 'finite', sourcePortals: const [0, 3], startType: 'finish', startMaxWaitFrames: 3));

      expect(
        engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(0))).presentation,
        _bodyFrame('idle', 1),
      );
      expect(
        engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(1))).presentation,
        _bodyFrame('idle', 2),
      );
      expect(
        engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(2))).presentation,
        _bodyFrame('idle', 3),
      );
      final held = engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(3)));
      expect(held.presentation, _bodyFrame('idle', 3));
      expect(held.effects, isEmpty);
      expect(held.snapshot.phase, MotionGraphPhase.stable);
      expect(held.snapshot.requestedState, 'idle');
      expect(held.snapshot.visualState, 'idle');
    });

    test('keeps a held body on frame zero until a finish route becomes ready', () {
      final engine = _animatedEngine(_graph(sourceKind: 'held', sourcePortals: const [0], startType: 'finish', startMaxWaitFrames: 0));
      engine.request('hover');

      final held = engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(0), routeReady: false));
      expect(held.presentation, _bodyFrame('idle', 0));
      expect(held.effects, isEmpty);
      expect(held.snapshot.phase, MotionGraphPhase.waiting);

      final commit = engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(1)));
      expect(commit.presentation, _bodyFrame('hover', 0));
      expect(commit.effects, [
        _transitionStart('idle-to-hover', 'idle', 'hover', 1),
        _visual('idle', 'hover'),
        _transitionEnd('idle-to-hover', 'idle', 'hover'),
        _settle([1], const GraphSettlementResolve(GraphSettlementResolveReason.targetCommitted)),
      ]);
    });

    test('plays an intro without transition effects and joins body frame zero', () {
      final engine = MotionGraphEngine();
      engine.install(_graph(introFrames: 2));
      final begin = engine.beginAnimated();
      expect(begin.presentation, _introFrame(0));
      expect(begin.effects, [_readiness(MotionGraphReadiness.preparing, MotionGraphReadiness.animated)]);
      expect(begin.snapshot.phase, MotionGraphPhase.intro);
      expect(begin.snapshot.visualState, 'idle');
      expect(begin.snapshot.requestedState, 'idle');
      expect(begin.snapshot.isTransitioning, false);

      final secondIntroFrame = engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(0)));
      expect(secondIntroFrame.presentation, _introFrame(1));
      expect(secondIntroFrame.effects, isEmpty);

      final bodyJoin = engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(1)));
      expect(bodyJoin.presentation, _bodyFrame('idle', 0));
      expect(bodyJoin.effects, isEmpty);
      expect(bodyJoin.snapshot.phase, MotionGraphPhase.stable);
      expect(bodyJoin.snapshot.visualState, 'idle');
      expect(bodyJoin.snapshot.requestedState, 'idle');
      expect(bodyJoin.snapshot.isTransitioning, false);
    });

    test('plays the intro before a request accepted during preparation', () {
      final engine = MotionGraphEngine();
      engine.install(_graph(introFrames: 2));
      final request = engine.request('hover');
      expect(request.effects, [_requested('idle', 'hover', 1)]);
      expect(request.snapshot.phase, MotionGraphPhase.preparing);

      final begin = engine.beginAnimated();
      expect(begin.presentation, _introFrame(0));
      expect(begin.effects, [_readiness(MotionGraphReadiness.preparing, MotionGraphReadiness.animated)]);
      expect(begin.snapshot.phase, MotionGraphPhase.intro);
      expect(begin.snapshot.requestedState, 'hover');
      expect(begin.snapshot.visualState, 'idle');
      expect(begin.snapshot.isTransitioning, true);

      expect(engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(0))).presentation, _introFrame(1));
      final join = engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(1)));
      expect(join.presentation, _bodyFrame('idle', 0));
      expect(join.effects, isEmpty);
      expect(join.snapshot.phase, MotionGraphPhase.waiting);

      final commit = engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(2)));
      expect(commit.presentation, _bodyFrame('hover', 0));
      expect(commit.effects, [
        _transitionStart('idle-to-hover', 'idle', 'hover', 1),
        _visual('idle', 'hover'),
        _transitionEnd('idle-to-hover', 'idle', 'hover'),
        _settle([1], const GraphSettlementResolve(GraphSettlementResolveReason.targetCommitted)),
      ]);
    });

    test('locks an accepted route behind a playing intro and draws body zero first', () {
      final engine = MotionGraphEngine();
      engine.install(_graph(introFrames: 2));
      engine.beginAnimated();

      final request = engine.request('hover');
      expect(request.effects, [_requested('idle', 'hover', 1)]);
      expect(request.snapshot.phase, MotionGraphPhase.intro);
      expect(request.snapshot.requestedState, 'hover');
      expect(request.snapshot.visualState, 'idle');
      expect(request.snapshot.isTransitioning, true);

      expect(engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(0))).presentation, _introFrame(1));
      final join = engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(1)));
      expect(join.presentation, _bodyFrame('idle', 0));
      expect(join.effects, isEmpty);
      expect(join.snapshot.phase, MotionGraphPhase.waiting);

      final commit = engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(2)));
      expect(commit.presentation, _bodyFrame('hover', 0));
      expect(commit.effects, [
        _transitionStart('idle-to-hover', 'idle', 'hover', 1),
        _visual('idle', 'hover'),
        _transitionEnd('idle-to-hover', 'idle', 'hover'),
        _settle([1], const GraphSettlementResolve(GraphSettlementResolveReason.targetCommitted)),
      ]);
    });

    test('treats the initial state as a semantic no-op while its intro continues', () {
      final engine = MotionGraphEngine();
      engine.install(_graph(introFrames: 2));
      engine.beginAnimated();

      final noop = engine.request('idle');
      expect(noop.effects, [
        _settle([1], const GraphSettlementResolve(GraphSettlementResolveReason.stableNoop)),
      ]);
      expect(noop.snapshot.phase, MotionGraphPhase.intro);
      expect(noop.snapshot.requestedState, 'idle');
      expect(noop.snapshot.visualState, 'idle');
      expect(noop.snapshot.isTransitioning, false);
      expect(engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(0))).presentation, _introFrame(1));
    });

    test('begins static mode by committing the newest prepared target in normative order', () {
      final engine = MotionGraphEngine();
      engine.install(_graph());
      engine.request('hover');

      final result = engine.beginStatic('codec-unsupported');
      expect(result.presentation, const GraphPresentationStatic(state: 'hover'));
      expect(result.effects, [
        _readiness(MotionGraphReadiness.preparing, MotionGraphReadiness.static, reason: 'codec-unsupported'),
        _fallback('codec-unsupported'),
        _transitionStart('idle-to-hover', 'idle', 'hover', 1),
        _visual('idle', 'hover'),
        _transitionEnd('idle-to-hover', 'idle', 'hover'),
        _settle([1], const GraphSettlementResolve(GraphSettlementResolveReason.staticRecovery)),
      ]);
      expect(result.snapshot.readiness, MotionGraphReadiness.static);
      expect(result.snapshot.phase, MotionGraphPhase.static);
      expect(result.snapshot.requestedState, 'hover');
      expect(result.snapshot.visualState, 'hover');
      expect(result.snapshot.isTransitioning, false);
      expect(result.snapshot.pendingRequestCount, 0);
    });

    test('uses direct-edge validation but ignores portal timing for later static requests', () {
      final engine = MotionGraphEngine();
      engine.install(_graph(sourcePortals: const [1, 3], startType: 'portal', startMaxWaitFrames: 1));
      final begin = engine.beginStatic('reduced-motion');
      expect(begin.presentation, const GraphPresentationStatic(state: 'idle'));
      expect(begin.effects, [
        _readiness(MotionGraphReadiness.preparing, MotionGraphReadiness.static, reason: 'reduced-motion'),
        _fallback('reduced-motion'),
      ]);

      final request = engine.request('hover');
      expect(request.presentation, const GraphPresentationStatic(state: 'hover'));
      expect(request.effects, [
        _requested('idle', 'hover', 1),
        _transitionStart('idle-to-hover', 'idle', 'hover', 1),
        _visual('idle', 'hover'),
        _transitionEnd('idle-to-hover', 'idle', 'hover'),
        _settle([1], const GraphSettlementResolve(GraphSettlementResolveReason.targetCommitted)),
      ]);
      expect(request.snapshot.readiness, MotionGraphReadiness.static);
      expect(request.snapshot.phase, MotionGraphPhase.static);
      expect(request.snapshot.requestedState, 'hover');
      expect(request.snapshot.visualState, 'hover');
      expect(request.snapshot.isTransitioning, false);
    });

    test('recovers pending animation to the requested static state before settling', () {
      final engine = _animatedEngine(_graph());
      engine.request('hover');

      final recovery = engine.recoverStatic('decode-failure');
      expect(recovery.presentation, const GraphPresentationStatic(state: 'hover'));
      expect(recovery.effects, [
        _readiness(MotionGraphReadiness.animated, MotionGraphReadiness.static, reason: 'decode-failure'),
        _fallback('decode-failure'),
        _transitionStart('idle-to-hover', 'idle', 'hover', 1),
        _visual('idle', 'hover'),
        _transitionEnd('idle-to-hover', 'idle', 'hover'),
        _settle([1], const GraphSettlementResolve(GraphSettlementResolveReason.staticRecovery)),
      ]);
      expect(recovery.snapshot.readiness, MotionGraphReadiness.static);
      expect(recovery.snapshot.phase, MotionGraphPhase.static);
      expect(recovery.snapshot.requestedState, 'hover');
      expect(recovery.snapshot.visualState, 'hover');
      expect(recovery.snapshot.isTransitioning, false);
      expect(recovery.snapshot.pendingRequestCount, 0);
    });

    test('rejects the surviving request when the required static frame cannot be installed', () {
      final engine = _animatedEngine(_graph());
      engine.request('hover');

      final failure = engine.failStatic('png-invalid');
      expect(failure.presentation, _bodyFrame('idle', 0));
      expect(failure.effects, [
        _readiness(MotionGraphReadiness.animated, MotionGraphReadiness.error, reason: 'png-invalid'),
        _settle([1], const GraphSettlementReject(GraphSettlementError.playbackFallbackError)),
      ]);
      expect(failure.snapshot.readiness, MotionGraphReadiness.error);
      expect(failure.snapshot.phase, MotionGraphPhase.error);
      expect(failure.snapshot.requestedState, 'hover');
      expect(failure.snapshot.visualState, 'idle');
      expect(failure.snapshot.isTransitioning, false);
      expect(failure.snapshot.pendingRequestCount, 0);
    });

    test('disposes idempotently, aborts pending requests, and remains terminal', () {
      final engine = _animatedEngine(_graph());
      final pending = engine.request('hover');

      final disposed = engine.dispose();
      expect(disposed.presentation, isNull);
      expect(disposed.effects, [
        _settle([pending.requestId!], const GraphSettlementReject(GraphSettlementError.abortError)),
        _readiness(MotionGraphReadiness.animated, MotionGraphReadiness.disposed),
      ]);
      expect(disposed.snapshot.readiness, MotionGraphReadiness.disposed);
      expect(disposed.snapshot.phase, MotionGraphPhase.disposed);
      expect(disposed.snapshot.pendingRequestCount, 0);

      expect(engine.dispose().effects, isEmpty);
      expect(
        () => engine.failStatic(),
        throwsA(isA<MotionGraphError>().having(
          (e) => e.message,
          'message',
          contains('disposed graph cannot fail static'),
        )),
      );
      expect(engine.snapshot().readiness, MotionGraphReadiness.disposed);
      expect(engine.snapshot().phase, MotionGraphPhase.disposed);
    });
  });
}

Map<String, Object?> _graph({
  String sourceKind = 'loop',
  List<int> sourcePortals = const [0, 2],
  int? introFrames,
  String startType = 'portal',
  int startMaxWaitFrames = 1,
}) {
  final sourceFrameCount = sourceKind == 'held' ? 1 : 4;
  final idle = <String, Object?>{
    'id': 'idle',
    'body': {
      'unitId': 'idle-body',
      'kind': sourceKind,
      'frameCount': sourceFrameCount,
      'ports': [
        {'id': 'handoff', 'entryFrame': 0, 'portalFrames': sourcePortals},
      ],
    },
    if (introFrames != null) 'initialUnit': {'unitId': 'idle-intro', 'frameCount': introFrames},
  };
  final hover = <String, Object?>{
    'id': 'hover',
    'body': {
      'unitId': 'hover-body',
      'kind': 'loop',
      'frameCount': 4,
      'ports': [
        {'id': 'handoff', 'entryFrame': 0, 'portalFrames': const [0, 2]},
      ],
    },
  };
  final Map<String, Object?> start;
  final Map<String, Object?> edge;
  if (startType == 'portal') {
    start = {
      'type': 'portal',
      'sourcePort': 'handoff',
      'targetPort': 'handoff',
      'maxWaitFrames': startMaxWaitFrames,
    };
    edge = {
      'id': 'idle-to-hover',
      'from': 'idle',
      'to': 'hover',
      'start': start,
      'continuity': 'exact-authored',
    };
  } else if (startType == 'finish') {
    start = {'type': 'finish', 'targetPort': 'handoff', 'maxWaitFrames': startMaxWaitFrames};
    edge = {
      'id': 'idle-to-hover',
      'from': 'idle',
      'to': 'hover',
      'start': start,
      'continuity': 'exact-authored',
    };
  } else {
    start = {'type': 'cut', 'targetPort': 'handoff', 'maxWaitFrames': 1};
    edge = {
      'id': 'idle-to-hover',
      'from': 'idle',
      'to': 'hover',
      'start': start,
      'continuity': 'cut',
    };
  }

  return {
    'initialState': 'idle',
    'states': [idle, hover],
    'edges': [edge],
  };
}

MotionGraphEngine _animatedEngine(Map<String, Object?> definition) {
  final engine = MotionGraphEngine();
  engine.install(definition);
  engine.beginAnimated();
  return engine;
}

GraphPresentationBody _bodyFrame(String state, int frameIndex) =>
    GraphPresentationBody(state: state, unitId: '$state-body', frameIndex: frameIndex);

GraphPresentationIntro _introFrame(int frameIndex) =>
    GraphPresentationIntro(state: 'idle', unitId: 'idle-intro', frameIndex: frameIndex);

MotionGraphEffectReadinessChange _readiness(
  MotionGraphReadiness from,
  MotionGraphReadiness to, {
  String? reason,
}) {
  return MotionGraphEffectReadinessChange(from: from, to: to, reason: reason);
}

MotionGraphEffectFallback _fallback(String reason) => MotionGraphEffectFallback(reason: reason);

MotionGraphEffectRequestedStateChange _requested(String from, String to, int sequence) =>
    MotionGraphEffectRequestedStateChange(from: from, to: to, sequence: sequence);

MotionGraphEffectVisualStateChange _visual(String from, String to) =>
    MotionGraphEffectVisualStateChange(from: from, to: to);

MotionGraphEffectTransitionStart _transitionStart(String edgeId, String from, String to, int sequence) =>
    MotionGraphEffectTransitionStart(edgeId: edgeId, from: from, to: to, sequence: sequence);

MotionGraphEffectTransitionEnd _transitionEnd(String edgeId, String from, String to) =>
    MotionGraphEffectTransitionEnd(edgeId: edgeId, from: from, to: to);

MotionGraphEffectSettle _settle(List<int> requestIds, GraphSettlement outcome) =>
    MotionGraphEffectSettle(requestIds: requestIds, outcome: outcome);
