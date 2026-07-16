// Ported from packages/graph/test/engine-failure-retention.test.ts
import 'package:aval_graph/aval_graph.dart';
import 'package:test/test.dart';

void main() {
  group('MotionGraphEngine failed presentation retention', () {
    test('restores the host\'s last drawn state when a committed cut cannot recover', () {
      final engine = MotionGraphEngine();
      engine.install({
        'initialState': 'idle',
        'states': [_state('idle'), _state('hover')],
        'edges': [
          {
            'id': 'idle-hover',
            'from': 'idle',
            'to': 'hover',
            'start': {'type': 'cut', 'targetPort': 'default', 'maxWaitFrames': 1},
            'continuity': 'cut',
          },
        ],
      });
      engine.beginAnimated();
      engine.request('hover');
      final committed = engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(0)));
      expect(committed.snapshot.visualState, 'hover');

      final failed = engine.failStatic(
        'recovery failed',
        const MotionGraphStaticFailureOptions(retainedVisualState: 'idle'),
      );
      expect(failed.presentation, const GraphPresentationStatic(state: 'idle'));
      expect(failed.snapshot.readiness, MotionGraphReadiness.error);
      expect(failed.snapshot.phase, MotionGraphPhase.error);
      expect(failed.snapshot.requestedState, 'hover');
      expect(failed.snapshot.visualState, 'idle');
      expect(failed.snapshot.isTransitioning, false);

      final failedSnapshot = engine.snapshot();
      final failedTrace = engine.getTrace();
      expect(
        () => engine.resumeAnimated(),
        throwsA(isA<MotionGraphError>().having((e) => e.message, 'message', contains('requires phase static'))),
      );
      expect(engine.snapshot(), failedSnapshot);
      expect(engine.getTrace(), failedTrace);
      expect(
        () => engine.failStatic(
          'again',
          const MotionGraphStaticFailureOptions(retainedVisualState: 'missing'),
        ),
        throwsA(isA<MotionGraphError>().having((e) => e.message, 'message', contains('retained visual state'))),
      );
    });

    test('recovers from the pixels actually retained after a superseded failed cut', () {
      final engine = MotionGraphEngine();
      engine.install({
        'initialState': 'idle',
        'states': [_state('idle'), _state('hover')],
        'edges': [_cut('idle-hover', 'idle', 'hover'), _cut('hover-idle', 'hover', 'idle')],
      });
      engine.beginAnimated();
      engine.request('hover');
      engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(0)));
      final latest = engine.request('idle');
      expect(latest.accepted, true);

      final recovered = engine.recoverStatic(
        'animation-failure',
        const MotionGraphRecoveryOptions(retainedVisualState: 'idle'),
      );

      expect(recovered.presentation, const GraphPresentationStatic(state: 'idle'));
      expect(recovered.snapshot.readiness, MotionGraphReadiness.static);
      expect(recovered.snapshot.requestedState, 'idle');
      expect(recovered.snapshot.visualState, 'idle');
      expect(recovered.snapshot.isTransitioning, false);
      expect(recovered.effects.map((e) => e.runtimeType), [
        MotionGraphEffectReadinessChange,
        MotionGraphEffectFallback,
        MotionGraphEffectSettle,
      ]);

      final resumed = engine.resumeAnimated();
      expect(resumed.operation, MotionGraphOperation.resumeAnimated);
      expect(
        resumed.presentation,
        const GraphPresentationBody(state: 'idle', unitId: 'idle-body', frameIndex: 0),
      );
      expect(resumed.snapshot.readiness, MotionGraphReadiness.animated);
      expect(resumed.snapshot.phase, MotionGraphPhase.stable);
      expect(resumed.snapshot.requestedState, 'idle');
      expect(resumed.snapshot.contentOrdinal, recovered.snapshot.contentOrdinal);
      expect(resumed.snapshot.inputSequence, recovered.snapshot.inputSequence);
      expect(resumed.snapshot.inputsSinceTick, recovered.snapshot.inputsSinceTick);
      expect(resumed.effects, [
        const MotionGraphEffectReadinessChange(from: MotionGraphReadiness.static, to: MotionGraphReadiness.animated),
      ]);
    });

    test('does not resume or clear a disposed terminal graph', () {
      final engine = MotionGraphEngine();
      engine.install({
        'initialState': 'idle',
        'states': [_state('idle')],
        'edges': <Object?>[],
      });
      engine.beginStatic('reduced-motion');
      engine.dispose();
      final snapshot = engine.snapshot();
      final trace = engine.getTrace();

      expect(
        () => engine.resumeAnimated(),
        throwsA(isA<MotionGraphError>().having((e) => e.message, 'message', contains('requires phase static'))),
      );
      expect(engine.snapshot(), snapshot);
      expect(engine.getTrace(), trace);
    });
  });
}

Map<String, Object?> _cut(String id, String from, String to) {
  return {
    'id': id,
    'from': from,
    'to': to,
    'start': {'type': 'cut', 'targetPort': 'default', 'maxWaitFrames': 1},
    'continuity': 'cut',
  };
}

Map<String, Object?> _state(String id) {
  return {
    'id': id,
    'body': {
      'unitId': '$id-body',
      'kind': 'loop',
      'frameCount': 2,
      'ports': [
        {'id': 'default', 'entryFrame': 0, 'portalFrames': const [0, 1]},
      ],
    },
  };
}
