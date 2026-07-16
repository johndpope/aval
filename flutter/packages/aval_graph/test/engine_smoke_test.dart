// Ported from packages/graph/test/engine-smoke.test.ts
import 'package:aval_graph/aval_graph.dart';
import 'package:test/test.dart';

void main() {
  group('MotionGraphEngine smoke', () {
    test('presents a portal bridge and commits only at target body zero', () {
      final engine = _preparedHoverEngine();
      final requested = engine.request('hovered');
      expect(requested.effects.map((e) => e.runtimeType), [MotionGraphEffectRequestedStateChange]);

      expect(_show(engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(0)))), 'body:idle:1');
      expect(_show(engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(1)))), 'body:idle:2');
      expect(
        _show(engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(2)))),
        'reversible:idle-to-hover:0:forward',
      );
      expect(
        _show(engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(3)))),
        'reversible:idle-to-hover:1:forward',
      );
      expect(
        _show(engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(4)))),
        'reversible:idle-to-hover:2:forward',
      );
      expect(
        _show(engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(5)))),
        'reversible:idle-to-hover:3:forward',
      );
      final committed = engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(6)));
      expect(_show(committed), 'body:hovered:0');
      expect(committed.snapshot.phase, MotionGraphPhase.stable);
      expect(committed.snapshot.requestedState, 'hovered');
      expect(committed.snapshot.visualState, 'hovered');
      expect(committed.snapshot.isTransitioning, false);
      expect(committed.effects.map((e) => e.runtimeType), [
        MotionGraphEffectVisualStateChange,
        MotionGraphEffectTransitionEnd,
        MotionGraphEffectSettle,
      ]);
    });

    test('reverses to the adjacent cached frame on the next tick', () {
      final engine = _preparedHoverEngine();
      engine.request('hovered');
      engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(0)));
      engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(1)));
      engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(2)));
      engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(3)));

      final inverse = engine.request('idle');
      expect(inverse.snapshot.requestedState, 'idle');
      expect(inverse.snapshot.visualState, 'idle');
      expect(inverse.snapshot.isTransitioning, true);
      expect(inverse.effects.map((e) => e.runtimeType), [
        MotionGraphEffectRequestedStateChange,
        MotionGraphEffectSettle,
      ]);

      final adjacent = engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(4)));
      expect(_show(adjacent), 'reversible:hover-to-idle:0:reverse');
      expect(adjacent.effects.map((e) => e.runtimeType), [MotionGraphEffectTransitionStart]);
      final returned = engine.tick(MotionGraphTickOptions(contentOrdinal: BigInt.from(5)));
      expect(_show(returned), 'body:idle:0');
      expect(returned.effects.map((e) => e.runtimeType), [
        MotionGraphEffectTransitionEnd,
        MotionGraphEffectSettle,
      ]);
    });
  });
}

MotionGraphEngine _preparedHoverEngine() {
  final engine = MotionGraphEngine();
  engine.install(_hoverGraph());
  engine.beginAnimated();
  return engine;
}

Map<String, Object?> _hoverGraph() {
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
            {'id': 'neutral', 'entryFrame': 0, 'portalFrames': [2]},
          ],
        },
      },
      {
        'id': 'hovered',
        'body': {
          'unitId': 'hover-body',
          'kind': 'loop',
          'frameCount': 3,
          'ports': [
            {'id': 'neutral', 'entryFrame': 0, 'portalFrames': [1]},
          ],
        },
      },
    ],
    'edges': [
      {
        'id': 'idle-to-hover',
        'from': 'idle',
        'to': 'hovered',
        'trigger': {'type': 'event', 'name': 'hover.enter'},
        'start': {
          'type': 'portal',
          'sourcePort': 'neutral',
          'targetPort': 'neutral',
          'maxWaitFrames': 3,
        },
        'transition': {
          'kind': 'reversible',
          'unitId': 'hover-clip',
          'frameCount': 4,
          'direction': 'forward',
        },
        'continuity': 'exact-authored',
      },
      {
        'id': 'hover-to-idle',
        'from': 'hovered',
        'to': 'idle',
        'trigger': {'type': 'event', 'name': 'hover.leave'},
        'start': {
          'type': 'portal',
          'sourcePort': 'neutral',
          'targetPort': 'neutral',
          'maxWaitFrames': 2,
        },
        'transition': {
          'kind': 'reversible',
          'unitId': 'hover-clip',
          'frameCount': 4,
          'direction': 'reverse',
          'reverseOf': 'idle-to-hover',
        },
        'continuity': 'exact-reverse',
      },
    ],
  };
}

String _show(MotionGraphResult result) {
  final presentation = result.presentation;
  if (presentation == null) return 'none';
  if (presentation is GraphPresentationBody) {
    return 'body:${presentation.state}:${presentation.frameIndex}';
  }
  if (presentation is GraphPresentationReversible) {
    return 'reversible:${presentation.edgeId}:${presentation.frameIndex}:${presentation.direction.name}';
  }
  return presentation.runtimeType.toString();
}
