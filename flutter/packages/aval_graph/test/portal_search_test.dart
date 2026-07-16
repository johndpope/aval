// Ported from packages/graph/test/portal-search.test.ts
import 'package:aval_graph/aval_graph.dart';
import 'package:test/test.dart';

void main() {
  group('body frame geometry', () {
    test('advances and wraps a loop, including a one-frame loop', () {
      final body = _loop(6, [0, 3]);
      expect(
        nextBodyFrame(body, 2),
        const BodyFrameStep(frameIndex: 3, didAdvance: true, wrapped: false, isHeld: false),
      );
      expect(
        nextBodyFrame(body, 5),
        const BodyFrameStep(frameIndex: 0, didAdvance: true, wrapped: true, isHeld: false),
      );
      expect(
        nextBodyFrame(_loop(1, [0]), 0),
        const BodyFrameStep(frameIndex: 0, didAdvance: true, wrapped: true, isHeld: false),
      );
    });

    test('advances a finite body once and then holds its final frame', () {
      final body = _finite(4, [3]);
      expect(
        nextBodyFrame(body, 2),
        const BodyFrameStep(frameIndex: 3, didAdvance: true, wrapped: false, isHeld: false),
      );
      expect(
        nextBodyFrame(body, 3),
        const BodyFrameStep(frameIndex: 3, didAdvance: false, wrapped: false, isHeld: true),
      );
    });

    test('never advances a held body', () {
      expect(
        nextBodyFrame(_held(), 0),
        const BodyFrameStep(frameIndex: 0, didAdvance: false, wrapped: false, isHeld: true),
      );
    });
  });

  group('portal geometry', () {
    test('treats a currently displayed portal as distance zero', () {
      final result = findNextPortalBoundary(_loop(12, [0, 4, 9]), 'handoff', 4);
      expect(
        result,
        const BodyBoundarySearch(boundaryFrame: 4, waitFrames: 0, eligibleNow: true, wraps: false),
      );
    });

    test('finds the next loop portal without wrapping', () {
      expect(
        findNextPortalBoundary(_loop(12, [0, 4, 9]), 'handoff', 5),
        const BodyBoundarySearch(boundaryFrame: 9, waitFrames: 4, eligibleNow: false, wraps: false),
      );
    });

    test('searches a looping body circularly', () {
      expect(
        findNextPortalBoundary(_loop(12, [0, 4, 9]), 'handoff', 10),
        const BodyBoundarySearch(boundaryFrame: 0, waitFrames: 2, eligibleNow: false, wraps: true),
      );
    });

    test('computes loop worst-case wait from portal gaps', () {
      expect(greatestPortalWaitFrames(_loop(12, [0, 4, 9]), 'handoff'), 4);
      expect(greatestPortalWaitFrames(_loop(12, [3]), 'handoff'), 11);
      expect(greatestPortalWaitFrames(_loop(1, [0]), 'handoff'), 0);
    });

    test('searches finite bodies only forward', () {
      final body = _finite(10, [2, 6, 9]);
      expect(
        findNextPortalBoundary(body, 'handoff', 3),
        const BodyBoundarySearch(boundaryFrame: 6, waitFrames: 3, eligibleNow: false, wraps: false),
      );
      expect(
        findNextPortalBoundary(body, 'handoff', 9),
        const BodyBoundarySearch(boundaryFrame: 9, waitFrames: 0, eligibleNow: true, wraps: false),
      );
      expect(greatestPortalWaitFrames(body, 'handoff'), 3);
    });

    test('uses frame zero immediately for a valid held port', () {
      expect(
        findNextPortalBoundary(_held(), 'handoff', 0),
        const BodyBoundarySearch(boundaryFrame: 0, waitFrames: 0, eligibleNow: true, wraps: false),
      );
      expect(greatestPortalWaitFrames(_held(), 'handoff'), 0);
    });
  });

  group('finish geometry', () {
    test('waits through the remaining finite frames and then remains eligible', () {
      final body = _finite(7, [6]);
      expect(
        findFinishBoundary(body, 2),
        const BodyBoundarySearch(boundaryFrame: 6, waitFrames: 4, eligibleNow: false, wraps: false),
      );
      expect(
        findFinishBoundary(body, 6),
        const BodyBoundarySearch(boundaryFrame: 6, waitFrames: 0, eligibleNow: true, wraps: false),
      );
      expect(greatestFinishWaitFrames(body), 6);
    });

    test('makes a held body immediately finish-eligible', () {
      expect(
        findFinishBoundary(_held(), 0),
        const BodyBoundarySearch(boundaryFrame: 0, waitFrames: 0, eligibleNow: true, wraps: false),
      );
      expect(greatestFinishWaitFrames(_held()), 0);
    });

    test('rejects finish geometry for an infinite loop', () {
      expect(
        () => findFinishBoundary(_loop(4, [0]), 0),
        throwsA(isA<MotionGraphValidationError>().having(
          (e) => e.message,
          'message',
          contains('cannot use a finish boundary'),
        )),
      );
      expect(
        () => greatestFinishWaitFrames(_loop(4, [0])),
        throwsA(isA<MotionGraphValidationError>().having(
          (e) => e.message,
          'message',
          contains('cannot use a finish boundary'),
        )),
      );
    });
  });

  group('geometry validation', () {
    test('rejects invalid current body frames', () {
      final body = _loop(4, [0]);
      for (final frame in [-1, 4]) {
        expect(
          () => nextBodyFrame(body, frame),
          throwsA(isA<MotionGraphValidationError>().having((e) => e.message, 'message', contains('out of range'))),
        );
        expect(
          () => findNextPortalBoundary(body, 'handoff', frame),
          throwsA(isA<MotionGraphValidationError>().having((e) => e.message, 'message', contains('out of range'))),
        );
      }
    });

    test('rejects a missing or duplicate named port', () {
      final body = _loop(4, [0]);
      expect(
        () => findNextPortalBoundary(body, 'missing', 0),
        throwsA(isA<MotionGraphValidationError>().having((e) => e.message, 'message', contains('has no port missing'))),
      );

      final duplicate = GraphBodyDefinition(
        unitId: body.unitId,
        kind: body.kind,
        frameCount: body.frameCount,
        ports: [body.ports[0], body.ports[0]],
      );
      expect(
        () => greatestPortalWaitFrames(duplicate, 'handoff'),
        throwsA(isA<MotionGraphValidationError>().having(
          (e) => e.message,
          'message',
          contains('duplicate port handoff'),
        )),
      );
    });

    test('rejects empty, unsorted, duplicate, and out-of-range portal frames', () {
      for (final portalFrames in [<int>[], [2, 1], [1, 1], [-1], [4]]) {
        final body = _loop(4, portalFrames);
        expect(
          () => greatestPortalWaitFrames(body, 'handoff'),
          throwsA(isA<MotionGraphValidationError>()),
        );
      }
    });

    test('rejects a finite departure port that omits the held final frame', () {
      final body = _finite(6, [1, 4]);
      expect(
        () => findNextPortalBoundary(body, 'handoff', 5),
        throwsA(isA<MotionGraphValidationError>().having(
          (e) => e.message,
          'message',
          contains('must include the final frame'),
        )),
      );
      expect(
        () => greatestPortalWaitFrames(body, 'handoff'),
        throwsA(isA<MotionGraphValidationError>().having(
          (e) => e.message,
          'message',
          contains('must include the final frame'),
        )),
      );
    });

    test('rejects malformed body geometry', () {
      final zeroFrame = _loop(1, [0]);
      expect(
        () => nextBodyFrame(
          GraphBodyDefinition(unitId: zeroFrame.unitId, kind: zeroFrame.kind, frameCount: 0, ports: zeroFrame.ports),
          0,
        ),
        throwsA(isA<MotionGraphValidationError>().having(
          (e) => e.message,
          'message',
          contains('positive safe integer'),
        )),
      );
      final held = _held();
      expect(
        () => nextBodyFrame(
          GraphBodyDefinition(unitId: held.unitId, kind: held.kind, frameCount: 2, ports: held.ports),
          0,
        ),
        throwsA(isA<MotionGraphValidationError>().having(
          (e) => e.message,
          'message',
          contains('exactly one frame'),
        )),
      );
    });
  });
}

GraphBodyDefinition _loop(int frameCount, List<int> portalFrames) =>
    _body(GraphBodyKind.loop, frameCount, portalFrames);

GraphBodyDefinition _finite(int frameCount, List<int> portalFrames) =>
    _body(GraphBodyKind.finite, frameCount, portalFrames);

GraphBodyDefinition _held() => _body(GraphBodyKind.held, 1, [0]);

GraphBodyDefinition _body(GraphBodyKind kind, int frameCount, List<int> portalFrames) {
  return GraphBodyDefinition(
    unitId: '${kind.name}-body',
    kind: kind,
    frameCount: frameCount,
    ports: [GraphPortDefinition(id: 'handoff', portalFrames: portalFrames)],
  );
}
