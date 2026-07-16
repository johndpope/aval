// Port of packages/player-web/src/runtime/submission-horizon.test.ts.
//
// Adaptation: the TS `Object.isFrozen` assertions become immutable-value
// (`is`) checks, since ported decisions/boundaries are immutable Dart classes.
import 'package:aval_graph/aval_graph.dart';
import 'package:aval_player/aval_player.dart';
import 'package:test/test.dart';

SourceBodyCursor _cursor(int occurrence, int frame) =>
    SourceBodyCursor(occurrence: BigInt.from(occurrence), frame: frame);

SourceBoundaryType _boundaryType(String type) => switch (type) {
      'portal' => SourceBoundaryType.portal,
      'finish' => SourceBoundaryType.finish,
      'cut' => SourceBoundaryType.cut,
      _ => throw ArgumentError('unknown boundary type $type'),
    };

SourceBoundary _boundary(String type, int occurrence, int frame, bool wraps) =>
    SourceBoundary(
      type: _boundaryType(type),
      occurrence: BigInt.from(occurrence),
      frame: frame,
      wraps: wraps,
    );

GraphBodyDefinition _body(
  GraphBodyKind kind,
  int frameCount,
  Map<String, List<int>> ports,
) {
  return GraphBodyDefinition(
    unitId: '${kind.name}-body',
    kind: kind,
    frameCount: frameCount,
    ports: ports.entries
        .map((entry) =>
            GraphPortDefinition(id: entry.key, portalFrames: entry.value))
        .toList(),
  );
}

GraphBodyDefinition _loop(int frameCount, Map<String, List<int>> ports) =>
    _body(GraphBodyKind.loop, frameCount, ports);

GraphBodyDefinition _finite(int frameCount, Map<String, List<int>> ports) =>
    _body(GraphBodyKind.finite, frameCount, ports);

GraphBodyDefinition _held() => _body(GraphBodyKind.held, 1, {
      'exit': [0],
    });

GraphStartPolicyPortal _portalStart(String sourcePort,
        [int maxWaitFrames = 12]) =>
    GraphStartPolicyPortal(
      sourcePort: sourcePort,
      targetPort: 'entry',
      maxWaitFrames: maxWaitFrames,
    );

GraphStartPolicyFinish _finishStart([int maxWaitFrames = 12]) =>
    GraphStartPolicyFinish(targetPort: 'entry', maxWaitFrames: maxWaitFrames);

GraphEdgeDefinition _edge(GraphStartPolicy start, [int? lockedFrames]) =>
    GraphEdgeDefinition(
      id: 'edge',
      from: 'source',
      to: 'target',
      start: start,
      continuity: start is GraphStartPolicyCut
          ? GraphContinuity.cut
          : GraphContinuity.exactAuthored,
      transition: lockedFrames == null
          ? null
          : GraphTransitionLocked(unitId: 'bridge', frameCount: lockedFrames),
    );

GraphEdgeDefinition _reversibleEdge(GraphStartPolicy start) =>
    GraphEdgeDefinition(
      id: 'reversible-edge',
      from: 'source',
      to: 'target',
      start: start,
      transition: const GraphTransitionReversible(
        unitId: 'resident-shift',
        frameCount: 6,
        direction: TransitionDirection.forward,
      ),
      continuity: GraphContinuity.exactAuthored,
    );

int _waitFramesOf(SubmissionHorizonDecision decision) {
  if (decision is SubmissionHorizonContinueSource) return decision.waitFrames;
  if (decision is SubmissionHorizonSelectPortal) return decision.waitFrames;
  return 0;
}

void main() {
  group('unresolved source submission horizon', () {
    test(
        'allows at most one ring capacity beyond the earliest unresolved portal',
        () {
      final body = _loop(12, {
        'first': [4, 10],
        'second': [7],
      });

      expect(
        planUnresolvedSubmissionHorizon(UnresolvedSubmissionHorizonInput(
          body: body,
          displayed: _cursor(0, 2),
          submitted: _cursor(0, 10),
          outgoingStarts: [_portalStart('first'), _portalStart('second')],
          ringCapacity: 6,
        )),
        UnresolvedSubmissionHorizon(
          earliestBoundary: _boundary('portal', 0, 4, false),
          maximumSubmitted: _cursor(0, 10),
          submittedWithinHorizon: true,
          framesBeyondEarliestBoundary: BigInt.from(6),
        ),
      );

      final beyond = planUnresolvedSubmissionHorizon(
        UnresolvedSubmissionHorizonInput(
          body: body,
          displayed: _cursor(0, 2),
          submitted: _cursor(0, 11),
          outgoingStarts: [_portalStart('first'), _portalStart('second')],
          ringCapacity: 6,
        ),
      );
      expect(beyond.maximumSubmitted, _cursor(0, 10));
      expect(beyond.submittedWithinHorizon, false);
      expect(beyond.framesBeyondEarliestBoundary, BigInt.from(7));
    });

    test('caps finite and held horizons at the final authored frame', () {
      final finiteResult = planUnresolvedSubmissionHorizon(
        UnresolvedSubmissionHorizonInput(
          body: _finite(4, {
            'exit': [3],
          }),
          displayed: _cursor(0, 1),
          submitted: _cursor(0, 3),
          outgoingStarts: [_finishStart()],
          ringCapacity: 12,
        ),
      );
      expect(finiteResult.earliestBoundary, _boundary('finish', 0, 3, false));
      expect(finiteResult.maximumSubmitted, _cursor(0, 3));
      expect(finiteResult.submittedWithinHorizon, true);

      final heldResult = planUnresolvedSubmissionHorizon(
        UnresolvedSubmissionHorizonInput(
          body: _held(),
          displayed: _cursor(0, 0),
          submitted: _cursor(0, 0),
          outgoingStarts: [_portalStart('exit')],
          ringCapacity: 6,
        ),
      );
      expect(heldResult.maximumSubmitted, _cursor(0, 0));
    });
  });

  group('selected portal submission planning', () {
    test(
        'discards speculative source debt only for a resident reversible portal',
        () {
      final body = _loop(8, {
        'exit': [7],
      });

      final reversible = planSubmissionHorizon(SubmissionHorizonInput(
        body: body,
        edge: _reversibleEdge(_portalStart('exit', 12)),
        displayed: _cursor(0, 0),
        submitted: _cursor(1, 5),
        ringCapacity: 6,
        availableConsecutiveEdgeFrames: 0,
        elapsedWaitFrames: 0,
      ));
      expect(reversible, isA<SubmissionHorizonSelectPortal>());
      reversible as SubmissionHorizonSelectPortal;
      expect(reversible.reason, SelectPortalReason.authoredBoundary);
      expect(reversible.boundary, _boundary('portal', 0, 7, false));
      expect(reversible.waitFrames, 7);
      expect(reversible.totalWaitFrames, 7);

      final streamed = planSubmissionHorizon(SubmissionHorizonInput(
        body: body,
        edge: _edge(_portalStart('exit', 12)),
        displayed: _cursor(0, 0),
        submitted: _cursor(1, 5),
        ringCapacity: 6,
        availableConsecutiveEdgeFrames: 2,
        elapsedWaitFrames: 0,
      ));
      expect(streamed, isA<SubmissionHorizonRejectReadiness>());
      streamed as SubmissionHorizonRejectReadiness;
      expect(streamed.reason, RejectReadinessReason.maxWaitExceeded);
      expect(streamed.requiredWaitFrames, BigInt.from(15));
      expect(streamed.maxWaitFrames, 12);
    });

    test(
        'selects a later portal when source submission has passed an early one',
        () {
      final decision = planSubmissionHorizon(SubmissionHorizonInput(
        body: _loop(12, {
          'exit': [2, 6, 9],
        }),
        edge: _edge(_portalStart('exit', 8)),
        displayed: _cursor(0, 3),
        submitted: _cursor(0, 7),
        ringCapacity: 6,
        availableConsecutiveEdgeFrames: 2,
        elapsedWaitFrames: 0,
      ));

      expect(decision, isA<SubmissionHorizonSelectPortal>());
      decision as SubmissionHorizonSelectPortal;
      expect(decision.reason, SelectPortalReason.submittedHorizon);
      expect(decision.boundary, _boundary('portal', 0, 9, false));
      expect(decision.waitFrames, 6);
      expect(decision.totalWaitFrames, 6);
    });

    test('searches a loop circularly without inventing a finite wrap', () {
      final decision = planSubmissionHorizon(SubmissionHorizonInput(
        body: _loop(12, {
          'exit': [0, 4, 9],
        }),
        edge: _edge(_portalStart('exit', 4)),
        displayed: _cursor(0, 10),
        submitted: _cursor(0, 11),
        ringCapacity: 6,
        availableConsecutiveEdgeFrames: 2,
        elapsedWaitFrames: 0,
      ));

      expect(decision, isA<SubmissionHorizonSelectPortal>());
      decision as SubmissionHorizonSelectPortal;
      expect(decision.boundary, _boundary('portal', 1, 0, true));
      expect(decision.waitFrames, 2);
      expect(decision.totalWaitFrames, 2);
    });

    test('commits a transitionless portal only with its two-frame lead', () {
      final committed = planSubmissionHorizon(SubmissionHorizonInput(
        body: _loop(6, {
          'exit': [0, 3],
        }),
        edge: _edge(_portalStart('exit', 3)),
        displayed: _cursor(0, 0),
        submitted: _cursor(0, 0),
        ringCapacity: 6,
        elapsedWaitFrames: 0,
        availableConsecutiveEdgeFrames: 2,
      ));
      expect(committed, isA<SubmissionHorizonCommitEdge>());
      committed as SubmissionHorizonCommitEdge;
      expect(committed.boundary, _boundary('portal', 0, 0, false));
      expect(committed.lead!.requiredConsecutiveFrames, 2);
      expect(committed.lead!.ready, true);

      final selected = planSubmissionHorizon(SubmissionHorizonInput(
        body: _loop(6, {
          'exit': [0, 3],
        }),
        edge: _edge(_portalStart('exit', 3)),
        displayed: _cursor(0, 0),
        submitted: _cursor(0, 0),
        ringCapacity: 6,
        elapsedWaitFrames: 0,
        availableConsecutiveEdgeFrames: 1,
      ));
      expect(selected, isA<SubmissionHorizonSelectPortal>());
      selected as SubmissionHorizonSelectPortal;
      expect(selected.reason, SelectPortalReason.leadUnavailable);
      expect(selected.boundary, _boundary('portal', 0, 3, false));
      expect(selected.waitFrames, 3);
    });

    test('requires one bridge frame followed by target frame zero', () {
      GraphEdgeDefinition locked() => _edge(_portalStart('exit', 3), 1);

      final low = planSubmissionHorizon(SubmissionHorizonInput(
        body: _loop(4, {
          'exit': [0, 2],
        }),
        edge: locked(),
        displayed: _cursor(0, 0),
        submitted: _cursor(0, 0),
        ringCapacity: 6,
        elapsedWaitFrames: 0,
        availableConsecutiveEdgeFrames: 1,
      ));
      expect(low, isA<SubmissionHorizonSelectPortal>());
      low as SubmissionHorizonSelectPortal;
      expect(low.reason, SelectPortalReason.leadUnavailable);
      expect(low.lead!.targetEntryOffset, 1);
      expect(low.lead!.requiredConsecutiveFrames, 2);
      expect(low.lead!.ready, false);

      final ready = planSubmissionHorizon(SubmissionHorizonInput(
        body: _loop(4, {
          'exit': [0, 2],
        }),
        edge: locked(),
        displayed: _cursor(0, 0),
        submitted: _cursor(0, 0),
        ringCapacity: 6,
        elapsedWaitFrames: 0,
        availableConsecutiveEdgeFrames: 2,
      ));
      expect(ready, isA<SubmissionHorizonCommitEdge>());
      ready as SubmissionHorizonCommitEdge;
      expect(ready.lead!.targetEntryOffset, 1);
      expect(ready.lead!.ready, true);
    });

    for (final testCase in const [
      [0, 0],
      [1, 2],
      [2, 1],
      [3, 0],
      [4, 2],
      [5, 1],
    ]) {
      final displayedFrame = testCase[0];
      final waitFrames = testCase[1];
      test('matches graph loop portal geometry from body frame $displayedFrame',
          () {
        final decision = planSubmissionHorizon(SubmissionHorizonInput(
          body: _loop(6, {
            'exit': [0, 3],
          }),
          edge: _edge(_portalStart('exit', 3)),
          displayed: _cursor(0, displayedFrame),
          submitted: _cursor(0, displayedFrame),
          ringCapacity: 6,
          availableConsecutiveEdgeFrames: 2,
          elapsedWaitFrames: 0,
        ));
        expect(
          decision.kind,
          waitFrames == 0 ? 'commit-edge' : 'select-portal',
        );
        expect(_waitFramesOf(decision), waitFrames);
      });
    }
  });

  group('finite, held, finish, and max-wait planning', () {
    test('selects only forward finite portals and holds the final portal', () {
      final selected = planSubmissionHorizon(SubmissionHorizonInput(
        body: _finite(4, {
          'exit': [1, 3],
        }),
        edge: _edge(_portalStart('exit', 4)),
        displayed: _cursor(0, 2),
        submitted: _cursor(0, 2),
        ringCapacity: 6,
        elapsedWaitFrames: 0,
        availableConsecutiveEdgeFrames: 2,
      ));
      expect(selected, isA<SubmissionHorizonSelectPortal>());
      selected as SubmissionHorizonSelectPortal;
      expect(selected.boundary, _boundary('portal', 0, 3, false));
      expect(selected.waitFrames, 1);

      final held = planSubmissionHorizon(SubmissionHorizonInput(
        body: _finite(4, {
          'exit': [1, 3],
        }),
        edge: _edge(_portalStart('exit', 4)),
        displayed: _cursor(0, 3),
        submitted: _cursor(0, 3),
        ringCapacity: 6,
        elapsedWaitFrames: 0,
        availableConsecutiveEdgeFrames: 1,
      ));
      expect(held, isA<SubmissionHorizonWaitHeld>());
      held as SubmissionHorizonWaitHeld;
      expect(held.boundary, _boundary('portal', 0, 3, false));
    });

    for (final frame in const [0, 1, 2, 3]) {
      test('matches finite finish geometry from frame $frame', () {
        final decision = planSubmissionHorizon(SubmissionHorizonInput(
          body: _finite(4, {
            'exit': [3],
          }),
          edge: _edge(_finishStart(3)),
          displayed: _cursor(0, frame),
          submitted: _cursor(0, frame),
          ringCapacity: 6,
          availableConsecutiveEdgeFrames: 2,
          elapsedWaitFrames: 0,
        ));
        expect(
          decision.kind,
          frame == 3 ? 'commit-edge' : 'continue-source',
        );
        expect(_waitFramesOf(decision), 3 - frame);
      });
    }

    test('holds a finite/held final boundary when lead is missing', () {
      for (final body in [
        _finite(4, {
          'exit': [3],
        }),
        _held(),
      ]) {
        final frame = body.frameCount - 1;
        final decision = planSubmissionHorizon(SubmissionHorizonInput(
          body: body,
          edge: _edge(_finishStart(4)),
          displayed: _cursor(0, frame),
          submitted: _cursor(0, frame),
          ringCapacity: 6,
          availableConsecutiveEdgeFrames: 1,
          elapsedWaitFrames: 2,
        ));
        expect(decision, isA<SubmissionHorizonWaitHeld>());
        decision as SubmissionHorizonWaitHeld;
        expect(decision.boundary, _boundary('finish', 0, frame, false));
        expect(decision.remainingWaitFrames, 2);
        expect(decision.lead.ready, false);
      }
    });

    test('allows the exact maxWaitFrames boundary and rejects one frame beyond',
        () {
      final within = planSubmissionHorizon(SubmissionHorizonInput(
        body: _loop(4, {
          'exit': [0, 2],
        }),
        edge: _edge(_portalStart('exit', 2)),
        displayed: _cursor(0, 1),
        submitted: _cursor(0, 1),
        ringCapacity: 6,
        availableConsecutiveEdgeFrames: 2,
        elapsedWaitFrames: 1,
      ));
      expect(within, isA<SubmissionHorizonSelectPortal>());
      within as SubmissionHorizonSelectPortal;
      expect(within.waitFrames, 1);
      expect(within.totalWaitFrames, 2);

      final beyond = planSubmissionHorizon(SubmissionHorizonInput(
        body: _loop(4, {
          'exit': [0, 2],
        }),
        edge: _edge(_portalStart('exit', 1)),
        displayed: _cursor(0, 1),
        submitted: _cursor(0, 1),
        ringCapacity: 6,
        availableConsecutiveEdgeFrames: 2,
        elapsedWaitFrames: 1,
      ));
      expect(beyond, isA<SubmissionHorizonRejectReadiness>());
      beyond as SubmissionHorizonRejectReadiness;
      expect(beyond.reason, RejectReadinessReason.maxWaitExceeded);
      expect(beyond.requiredWaitFrames, BigInt.from(2));
      expect(beyond.maxWaitFrames, 1);
    });

    test('restarts a generation for a one-tick cut', () {
      final decision = planSubmissionHorizon(SubmissionHorizonInput(
        body: _loop(4, {
          'exit': [0],
        }),
        edge: _edge(const GraphStartPolicyCut(targetPort: 'entry')),
        displayed: _cursor(0, 2),
        submitted: _cursor(0, 3),
        ringCapacity: 6,
        availableConsecutiveEdgeFrames: 0,
        elapsedWaitFrames: 0,
      ));
      expect(decision, isA<SubmissionHorizonRestartGeneration>());
      decision as SubmissionHorizonRestartGeneration;
      expect(decision.reason, 'cut');
      expect(decision.responseFrames, 1);
      expect(decision.totalWaitFrames, 1);
    });
  });

  group('submission planner validation', () {
    test(
        'rejects malformed cursors, backwards submission, and invalid ring lead',
        () {
      GraphBodyDefinition loopBody() => _loop(4, {
            'exit': [0, 2],
          });

      expect(
        () => planSubmissionHorizon(SubmissionHorizonInput(
          body: loopBody(),
          edge: _edge(_portalStart('exit', 3)),
          displayed: _cursor(1, 0),
          submitted: _cursor(0, 3),
          ringCapacity: 6,
          availableConsecutiveEdgeFrames: 2,
          elapsedWaitFrames: 0,
        )),
        throwsA(
          isA<RangeError>().having(
            (e) => e.toString(),
            'message',
            contains('behind'),
          ),
        ),
      );
      expect(
        () => planSubmissionHorizon(SubmissionHorizonInput(
          body: loopBody(),
          edge: _edge(_portalStart('exit', 3)),
          displayed: _cursor(0, 4),
          submitted: _cursor(0, 4),
          ringCapacity: 6,
          availableConsecutiveEdgeFrames: 2,
          elapsedWaitFrames: 0,
        )),
        throwsA(
          isA<RangeError>().having(
            (e) => e.toString(),
            'message',
            contains('out of range'),
          ),
        ),
      );
      expect(
        () => planSubmissionHorizon(SubmissionHorizonInput(
          body: loopBody(),
          edge: _edge(_portalStart('exit', 3)),
          displayed: _cursor(0, 0),
          submitted: _cursor(0, 0),
          ringCapacity: 6,
          availableConsecutiveEdgeFrames: 7,
          elapsedWaitFrames: 0,
        )),
        throwsA(
          isA<RangeError>().having(
            (e) => e.toString(),
            'message',
            contains('available consecutive'),
          ),
        ),
      );
      expect(
        () => planSubmissionHorizon(SubmissionHorizonInput(
          body: _finite(4, {
            'exit': [3],
          }),
          edge: _edge(_portalStart('exit', 3)),
          displayed: _cursor(1, 0),
          submitted: _cursor(1, 0),
          ringCapacity: 6,
          availableConsecutiveEdgeFrames: 2,
          elapsedWaitFrames: 0,
        )),
        throwsA(
          isA<RangeError>().having(
            (e) => e.toString(),
            'message',
            contains('occurrence zero'),
          ),
        ),
      );

      final huge = planSubmissionHorizon(SubmissionHorizonInput(
        body: loopBody(),
        edge: _edge(_portalStart('exit', 3)),
        displayed: _cursor(0, 0),
        submitted: SourceBodyCursor(
          occurrence: BigInt.from(maxSafeInteger) * BigInt.from(1000000),
          frame: 0,
        ),
        ringCapacity: 6,
        availableConsecutiveEdgeFrames: 2,
        elapsedWaitFrames: 0,
      ));
      expect(huge, isA<SubmissionHorizonRejectReadiness>());
      huge as SubmissionHorizonRejectReadiness;
      expect(huge.reason, RejectReadinessReason.maxWaitExceeded);
    });

    test('returns immutable decisions and nested boundaries', () {
      final decision = planSubmissionHorizon(SubmissionHorizonInput(
        body: _loop(4, {
          'exit': [0, 2],
        }),
        edge: _edge(_portalStart('exit', 3)),
        displayed: _cursor(0, 1),
        submitted: _cursor(0, 1),
        ringCapacity: 6,
        availableConsecutiveEdgeFrames: 2,
        elapsedWaitFrames: 0,
      ));
      expect(decision, isA<SubmissionHorizonSelectPortal>());
      decision as SubmissionHorizonSelectPortal;
      expect(decision.boundary, isA<SourceBoundary>());
    });
  });
}
