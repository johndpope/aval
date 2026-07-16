// Ported from packages/graph/test/engine-resume.test.ts
import 'package:aval_graph/aval_graph.dart';
import 'package:test/test.dart';

void main() {
  group('MotionGraphEngine animated reentry', () {
    test('plays the intro when first animated activation follows static preparation', () {
      final engine = MotionGraphEngine();
      engine.install(_graph('loop', introFrames: 2));
      final reduced = engine.beginStatic('reduced-motion');

      final resumed = engine.resumeAnimated();

      expect(resumed.operation, MotionGraphOperation.resumeAnimated);
      expect(resumed.presentation, _introFrame(0));
      expect(resumed.effects, [_readiness(MotionGraphReadiness.static, MotionGraphReadiness.animated)]);
      expect(resumed.snapshot.readiness, MotionGraphReadiness.animated);
      expect(resumed.snapshot.phase, MotionGraphPhase.intro);
      expect(resumed.snapshot.presentation, _introFrame(0));
      expect(resumed.snapshot.requestedState, reduced.snapshot.requestedState);
      expect(resumed.snapshot.visualState, reduced.snapshot.visualState);
    });

    test('does not replay an intro that already reached its body', () {
      final engine = MotionGraphEngine();
      engine.install(_graph('loop', introFrames: 2));
      engine.beginAnimated();
      engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(0)));
      engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(1)));
      engine.recoverStatic('visibility-hidden');

      final resumed = engine.resumeAnimated();

      expect(resumed.operation, MotionGraphOperation.resumeAnimated);
      expect(resumed.presentation, _bodyFrame('idle', 0));
      expect(resumed.snapshot.readiness, MotionGraphReadiness.animated);
      expect(resumed.snapshot.phase, MotionGraphPhase.stable);
      expect(resumed.snapshot.presentation, _bodyFrame('idle', 0));
      expect(resumed.snapshot.initialUnitPending, false);
      expect(resumed.snapshot.contentOrdinal, BigInt.from(1));
    });

    test('restarts an intro suspended before it reaches the body', () {
      final engine = MotionGraphEngine();
      engine.install(_graph('loop', introFrames: 3));
      engine.beginAnimated();
      engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(0)));
      final mid = engine.snapshot();
      expect(mid.phase, MotionGraphPhase.intro);
      expect(mid.initialUnitPending, true);
      expect(mid.presentation, _introFrame(1));
      engine.recoverStatic('visibility-hidden');

      final resumed = engine.resumeAnimated();

      expect(resumed.operation, MotionGraphOperation.resumeAnimated);
      expect(resumed.presentation, _introFrame(0));
      expect(resumed.snapshot.phase, MotionGraphPhase.intro);
      expect(resumed.snapshot.initialUnitPending, true);
      expect(resumed.snapshot.presentation, _introFrame(0));
    });

    test('rolls back intro consumption when the body join is only previewed', () {
      final engine = MotionGraphEngine();
      engine.install(_graph('loop', introFrames: 2));
      engine.beginAnimated();
      engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(0)));
      final before = engine.snapshot();

      final preview = engine.previewTick(MotionGraphTickOptions(contentOrdinal: BigInt.from(1)));

      expect(preview.presentation, _bodyFrame('idle', 0));
      expect(preview.snapshot.phase, MotionGraphPhase.stable);
      expect(preview.snapshot.initialUnitPending, false);
      expect(engine.snapshot(), before);
      expect(before.phase, MotionGraphPhase.intro);
      expect(before.initialUnitPending, true);
      expect(before.presentation, _introFrame(1));
      expect(engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(1))), preview);
    });

    test('does not replay an intro after an explicit noninitial static commit', () {
      final engine = MotionGraphEngine();
      engine.install(_graph('loop', introFrames: 3));
      engine.beginStatic('reduced-motion');
      engine.request('hover');
      expect(engine.snapshot().initialUnitPending, false);
      engine.request('idle');

      final resumed = engine.resumeAnimated();

      expect(resumed.presentation, _bodyFrame('idle', 0));
      expect(resumed.snapshot.phase, MotionGraphPhase.stable);
      expect(resumed.snapshot.initialUnitPending, false);
      expect(resumed.snapshot.presentation, _bodyFrame('idle', 0));
    });

    for (final bodyKind in const ['loop', 'finite', 'held']) {
      test('resumes a noninitial $bodyKind state at body frame zero', () {
        final engine = MotionGraphEngine();
        engine.install(_graph(bodyKind));
        engine.request('hover');
        final reduced = engine.beginStatic('reduced-motion');
        expect(reduced.snapshot.requestedState, 'hover');
        expect(reduced.snapshot.visualState, 'hover');
        expect(reduced.snapshot.pendingRequestCount, 0);
        expect(reduced.snapshot.pendingEdgeId, isNull);
        expect(reduced.snapshot.activeEdgeId, isNull);
        expect(reduced.snapshot.followOnEdgeId, isNull);

        final resumed = engine.resumeAnimated();

        expect(resumed.operation, MotionGraphOperation.resumeAnimated);
        expect(resumed.presentation, _bodyFrame('hover', 0));
        expect(resumed.effects, [_readiness(MotionGraphReadiness.static, MotionGraphReadiness.animated)]);
        expect(resumed.snapshot.readiness, MotionGraphReadiness.animated);
        expect(resumed.snapshot.phase, MotionGraphPhase.stable);
        expect(resumed.snapshot.requestedState, 'hover');
        expect(resumed.snapshot.visualState, 'hover');
        expect(resumed.snapshot.prospectiveState, 'hover');
        expect(resumed.snapshot.isTransitioning, false);
        expect(resumed.snapshot.pendingRequestCount, 0);
        expect(resumed.snapshot.inputSequence, 1);
        expect(resumed.snapshot.inputsSinceTick, 1);
        expect(resumed.snapshot.contentOrdinal, isNull);
      });
    }

    test('rejects resume outside static phase without mutating state', () {
      final unready = MotionGraphEngine();
      expect(
        () => unready.resumeAnimated(),
        throwsA(isA<MotionGraphError>().having((e) => e.message, 'message', contains('requires graph metadata'))),
      );

      final engine = MotionGraphEngine();
      engine.install(_graph('loop'));
      final preparing = engine.snapshot();
      final preparingTrace = engine.getTrace();
      expect(
        () => engine.resumeAnimated(),
        throwsA(isA<MotionGraphError>().having((e) => e.message, 'message', contains('requires phase static'))),
      );
      expect(engine.snapshot(), preparing);
      expect(engine.getTrace(), preparingTrace);

      engine.beginStatic('reduced-motion');
      engine.resumeAnimated();
      final animated = engine.snapshot();
      final animatedTrace = engine.getTrace();
      expect(
        () => engine.resumeAnimated(),
        throwsA(isA<MotionGraphError>().having((e) => e.message, 'message', contains('requires phase static'))),
      );
      expect(engine.snapshot(), animated);
      expect(engine.getTrace(), animatedTrace);
    });
  });
}

Map<String, Object?> _graph(String hoverKind, {int? introFrames}) {
  final hoverFrames = hoverKind == 'held' ? 1 : 4;
  return {
    'initialState': 'idle',
    'states': [
      {
        'id': 'idle',
        'body': {
          'unitId': 'idle-body',
          'kind': 'loop',
          'frameCount': 4,
          'ports': [
            {'id': 'handoff', 'entryFrame': 0, 'portalFrames': const [0, 2]},
          ],
        },
        if (introFrames != null) 'initialUnit': {'unitId': 'idle-intro', 'frameCount': introFrames},
      },
      {
        'id': 'hover',
        'body': {
          'unitId': 'hover-body',
          'kind': hoverKind,
          'frameCount': hoverFrames,
          'ports': [
            {
              'id': 'handoff',
              'entryFrame': 0,
              'portalFrames': hoverKind == 'held' ? const [0] : [0, hoverFrames - 1],
            },
          ],
        },
      },
    ],
    'edges': [
      {
        'id': 'idle-to-hover',
        'from': 'idle',
        'to': 'hover',
        'start': {'type': 'cut', 'targetPort': 'handoff', 'maxWaitFrames': 1},
        'continuity': 'cut',
      },
      {
        'id': 'hover-to-idle',
        'from': 'hover',
        'to': 'idle',
        'start': {'type': 'cut', 'targetPort': 'handoff', 'maxWaitFrames': 1},
        'continuity': 'cut',
      },
    ],
  };
}

GraphPresentationBody _bodyFrame(String state, int frameIndex) =>
    GraphPresentationBody(state: state, unitId: '$state-body', frameIndex: frameIndex);

GraphPresentationIntro _introFrame(int frameIndex) =>
    GraphPresentationIntro(state: 'idle', unitId: 'idle-intro', frameIndex: frameIndex);

MotionGraphEffectReadinessChange _readiness(MotionGraphReadiness from, MotionGraphReadiness to) =>
    MotionGraphEffectReadinessChange(from: from, to: to);
