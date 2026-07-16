// Ported from packages/graph/test/route-plan.test.ts
import 'package:aval_graph/aval_graph.dart';
import 'package:aval_graph/src/route_plan.dart';
import 'package:test/test.dart';

void main() {
  group('RoutePlan', () {
    test('keeps a pending edge and sequence in one immutable value', () {
      final plan = RoutePlan();

      final pending = plan.replacePending(edgeAB, 17);

      expect(pending.edge, same(edgeAB));
      expect(pending.sequence, 17);
      expect(plan.pending, same(pending));
      expect(plan.prospectiveState('a'), 'b');
      expect(plan.hasRoute(), true);
    });

    test('cancels a pending route without changing its returned value', () {
      final plan = RoutePlan();
      final pending = plan.replacePending(edgeAB, 2);

      expect(plan.cancelPending(), same(pending));
      expect(plan.cancelPending(), isNull);
      expect(plan.prospectiveState('a'), 'a');
      expect(plan.hasRoute(), false);
    });

    test('activates a matching pending route without rebuilding its atomic ref', () {
      final plan = RoutePlan();
      final pending = plan.replacePending(edgeAB, 3);

      final active = plan.activate(edgeAB, 3);

      expect(active, same(pending));
      expect(plan.pending, isNull);
      expect(plan.active, same(active));
      expect(plan.recoveryCandidate(), same(active));
    });

    test('activates a completion route directly when no edge was pending', () {
      final plan = RoutePlan();

      final active = plan.activate(edgeAB, 4);

      expect(active.edge, same(edgeAB));
      expect(active.sequence, 4);
      expect(plan.active, same(active));
      expect(plan.pending, isNull);
    });

    test('queues one follow-on from the effective active target', () {
      final plan = _activePlan();

      final first = plan.queueFollowOn(edgeBC, 5);
      final replacement = plan.queueFollowOn(edgeBD, 6);

      expect(first, isNot(same(replacement)));
      expect(plan.followOn, same(replacement));
      expect(plan.prospectiveState('a'), 'd');
      expect(plan.clearFollowOn(), same(replacement));
      expect(plan.followOn, isNull);
    });

    test('queues a reversal atomically and discards an older follow-on', () {
      final plan = _activePlan();
      plan.queueFollowOn(edgeBC, 5);

      final reversal = plan.queueReversal(edgeBA, 6);

      expect(plan.followOn, isNull);
      expect(plan.reversal, same(reversal));
      expect(plan.prospectiveState('a'), 'a');
      expect(plan.recoveryCandidate(), same(reversal));
    });

    test('allows a continuation after a queued reversal and preserves it on activation', () {
      final plan = _activePlan();
      final reversal = plan.queueReversal(edgeBA, 7);
      final followOn = plan.queueFollowOn(edgeAC, 8);

      expect(plan.prospectiveState('a'), 'c');
      expect(plan.recoveryCandidate(), same(followOn));

      expect(plan.activateReversal(), same(reversal));
      expect(plan.active, same(reversal));
      expect(plan.reversal, isNull);
      expect(plan.followOn, same(followOn));
    });

    test('promotes a follow-on to pending when the active edge completes', () {
      final plan = _activePlan();
      final followOn = plan.queueFollowOn(edgeBC, 9);

      final completion = plan.completeActive();

      expect(completion.completed.edge, same(edgeAB));
      expect(completion.completed.sequence, 1);
      expect(completion.promoted, same(followOn));
      expect(plan.active, isNull);
      expect(plan.followOn, isNull);
      expect(plan.pending, same(followOn));
    });

    test('clears a queued reversal when an active edge completes', () {
      final plan = _activePlan();
      plan.queueReversal(edgeBA, 10);

      final completion = plan.completeActive();

      expect(completion.promoted, isNull);
      expect(plan.active, isNull);
      expect(plan.reversal, isNull);
      expect(plan.hasRoute(), false);
    });

    test('uses follow-on, reversal, active, and pending recovery priority', () {
      final plan = _activePlan();
      final active = plan.active;
      final reversal = plan.queueReversal(edgeBA, 11);
      final followOn = plan.queueFollowOn(edgeAC, 12);

      expect(plan.recoveryCandidate(), same(followOn));
      plan.clearFollowOn();
      expect(plan.recoveryCandidate(), same(reversal));
      plan.clearReversal();
      expect(plan.recoveryCandidate(), same(active));
      plan.completeActive();
      expect(plan.recoveryCandidate(), isNull);

      final pending = plan.replacePending(edgeAB, 13);
      expect(plan.recoveryCandidate(), same(pending));
    });

    test('exposes structural read-only slots to pure route consumers', () {
      final plan = _activePlan();
      final RoutePlanView view = plan;

      expect(view.prospectiveState('a'), 'b');
      expect(view.recoveryCandidate()?.edge.id, 'a-to-b');
    });

    test('clears every slot without retaining stale sequences', () {
      final plan = _activePlan();
      plan.queueReversal(edgeBA, 14);
      plan.queueFollowOn(edgeAC, 15);

      plan.clear();

      expect(plan.pending, isNull);
      expect(plan.active, isNull);
      expect(plan.followOn, isNull);
      expect(plan.reversal, isNull);
      expect(plan.hasRoute(), false);
      expect(plan.prospectiveState(null), isNull);
    });

    test('rejects cross-slot topology mistakes', () {
      final pendingPlan = RoutePlan();
      pendingPlan.replacePending(edgeAB, 1);
      expect(
        () => pendingPlan.activate(edgeAB, 2),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('activated route does not match the pending route'),
        )),
      );

      final active = _activePlan();
      expect(
        () => active.replacePending(edgeAB, 2),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('active route must complete'))),
      );
      expect(
        () => active.queueFollowOn(edgeAC, 2),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('follow-on source must match'))),
      );
      expect(
        () => active.queueReversal(edgeCA, 2),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('reversal must invert'))),
      );
    });

    test('rejects missing slots and invalid route sequences', () {
      final plan = RoutePlan();

      expect(
        () => plan.activateReversal(),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('no active route'))),
      );
      expect(
        () => plan.completeActive(),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('no active route'))),
      );
      // TypeScript additionally asserts `replacePending(EDGE_AB, Number.MAX_VALUE)`
      // throws RangeError. Dart's `int` sequence parameter has no
      // non-integer/unsafe-magnitude representation (unlike JS `number`), so
      // that specific overflow path is unreachable here; the negative-sequence
      // guard below is the only reachable RangeError trigger.
      expect(() => plan.replacePending(edgeAB, -1), throwsA(isA<RangeError>()));
    });
  });
}

RoutePlan _activePlan() {
  final plan = RoutePlan();
  plan.activate(edgeAB, 1);
  return plan;
}

GraphEdgeDefinition _edge(String id, String from, String to) {
  return GraphEdgeDefinition(
    id: id,
    from: from,
    to: to,
    start: const GraphStartPolicyCut(targetPort: 'entry'),
    continuity: GraphContinuity.cut,
  );
}

final edgeAB = _edge('a-to-b', 'a', 'b');
final edgeBA = _edge('b-to-a', 'b', 'a');
final edgeBC = _edge('b-to-c', 'b', 'c');
final edgeBD = _edge('b-to-d', 'b', 'd');
final edgeAC = _edge('a-to-c', 'a', 'c');
final edgeCA = _edge('c-to-a', 'c', 'a');
