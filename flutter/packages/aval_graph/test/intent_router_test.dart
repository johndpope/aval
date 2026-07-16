// Ported from packages/graph/test/intent-router.test.ts
import 'package:aval_graph/aval_graph.dart';
import 'package:aval_graph/src/intent_router.dart';
import 'package:aval_graph/src/route_plan.dart';
import 'package:aval_graph/src/validate.dart';
import 'package:test/test.dart';

void main() {
  final indexes = getValidatedGraphIndexes(validateMotionGraphDefinition(_graph()));

  group('planStateIntent', () {
    test('plans standalone no-ops for settled visual-state requests', () {
      for (final phase in [
        MotionGraphPhase.preparing,
        MotionGraphPhase.intro,
        MotionGraphPhase.stable,
        MotionGraphPhase.static,
      ]) {
        expect(planStateIntent(_context(indexes, phase), 'idle'), const StateIntentPlanStandaloneNoop());
      }
    });

    test('cancels preparation and intro routes selected by requests or events', () {
      final pending = _edge(indexes, 'idle-hover');

      for (final phase in [MotionGraphPhase.preparing, MotionGraphPhase.intro]) {
        expect(
          planStateIntent(_context(indexes, phase, pending: pending, hasPendingRequests: true), 'idle'),
          const StateIntentPlanCancelBeforeStable(),
        );
        // An event-owned route has no request group but is still older intent.
        expect(
          planStateIntent(_context(indexes, phase, pending: pending), 'idle'),
          const StateIntentPlanCancelBeforeStable(),
        );
      }
    });

    test('replaces valid pending routes before and after readiness', () {
      for (final phase in [MotionGraphPhase.preparing, MotionGraphPhase.intro, MotionGraphPhase.stable]) {
        expect(
          planStateIntent(_context(indexes, phase), 'hover'),
          StateIntentPlanReplacePending(_edge(indexes, 'idle-hover')),
        );
      }

      expect(
        planStateIntent(
          _context(indexes, MotionGraphPhase.waiting, pending: _edge(indexes, 'idle-hover')),
          'loading',
        ),
        StateIntentPlanReplacePending(_edge(indexes, 'idle-loading')),
      );
    });

    test('joins, cancels, or rejects a waiting route without ambiguity', () {
      final waiting = _context(indexes, MotionGraphPhase.waiting, pending: _edge(indexes, 'idle-hover'));

      expect(planStateIntent(waiting, 'hover'), const StateIntentPlanJoinPending());
      expect(planStateIntent(waiting, 'idle'), const StateIntentPlanCancelPending());
      expect(planStateIntent(waiting, 'success'), const StateIntentPlanReject());
    });

    test('commits only direct edges in static mode', () {
      expect(
        planStateIntent(_context(indexes, MotionGraphPhase.static), 'error'),
        StateIntentPlanStaticCommit(_edge(indexes, 'idle-error')),
      );
      expect(
        planStateIntent(_context(indexes, MotionGraphPhase.static), 'success'),
        const StateIntentPlanReject(),
      );
    });

    test('treats locked and reversible active targets symmetrically', () {
      final cases = [
        (
          phase: MotionGraphPhase.locked,
          active: _edge(indexes, 'idle-loading'),
          target: 'loading',
          followOn: _edge(indexes, 'loading-success'),
        ),
        (
          phase: MotionGraphPhase.reversible,
          active: _edge(indexes, 'idle-hover'),
          target: 'hover',
          followOn: _edge(indexes, 'hover-success'),
        ),
      ];

      for (final c in cases) {
        expect(
          planStateIntent(_context(indexes, c.phase, active: c.active), c.target),
          const StateIntentPlanContinueActiveTarget(),
        );
        expect(
          planStateIntent(_context(indexes, c.phase, active: c.active), 'success'),
          StateIntentPlanQueueFollowOn(c.followOn),
        );
      }
    });

    test('queues an authored inverse only for a reversible transition', () {
      expect(
        planStateIntent(
          _context(indexes, MotionGraphPhase.reversible, active: _edge(indexes, 'idle-hover')),
          'idle',
        ),
        StateIntentPlanQueueReversal(_edge(indexes, 'hover-idle')),
      );

      expect(
        planStateIntent(
          _context(indexes, MotionGraphPhase.locked, active: _edge(indexes, 'idle-loading')),
          'idle',
        ),
        const StateIntentPlanReject(),
      );
    });

    test('routes from a queued reversal target and never from an old follow-on', () {
      final reversing = _context(
        indexes,
        MotionGraphPhase.reversible,
        active: _edge(indexes, 'idle-hover'),
        reversal: _edge(indexes, 'hover-idle'),
        followOn: _edge(indexes, 'idle-error'),
      );

      expect(planStateIntent(reversing, 'hover'), const StateIntentPlanContinueActiveTarget());
      expect(planStateIntent(reversing, 'idle'), const StateIntentPlanContinueReversalTarget());
      expect(
        planStateIntent(reversing, 'error'),
        StateIntentPlanQueueFollowOn(_edge(indexes, 'idle-error')),
      );

      // success is reachable from the old active target, not the effective
      // reversal target, so it is not a valid direct follow-on.
      expect(planStateIntent(reversing, 'success'), const StateIntentPlanReject());
    });

    test('rejects invalid direct follow-ons in both transition phases', () {
      expect(
        planStateIntent(
          _context(indexes, MotionGraphPhase.reversible, active: _edge(indexes, 'idle-hover')),
          'error',
        ),
        const StateIntentPlanReject(),
      );
      expect(
        planStateIntent(
          _context(indexes, MotionGraphPhase.locked, active: _edge(indexes, 'idle-loading')),
          'error',
        ),
        const StateIntentPlanReject(),
      );
    });
  });

  group('planEventIntent', () {
    test('replaces valid event routes in stable, preparing, and intro phases', () {
      for (final phase in [MotionGraphPhase.stable, MotionGraphPhase.preparing, MotionGraphPhase.intro]) {
        expect(
          planEventIntent(_context(indexes, phase), 'hover.enter'),
          EventIntentPlanReplacePending(_edge(indexes, 'idle-hover')),
        );
      }
    });

    test('keeps a duplicate preparation or intro event as an accepted no-op', () {
      for (final phase in [MotionGraphPhase.preparing, MotionGraphPhase.intro]) {
        expect(
          planEventIntent(_context(indexes, phase, pending: _edge(indexes, 'idle-hover')), 'hover.enter'),
          const EventIntentPlanAcceptNoop(),
        );
      }
    });

    test('cancels a waiting route through its inverse before visual lookup', () {
      final waiting = _context(indexes, MotionGraphPhase.waiting, pending: _edge(indexes, 'idle-hover'));

      expect(
        planEventIntent(waiting, 'hover.leave'),
        EventIntentPlanCancelPending(_edge(indexes, 'hover-idle')),
      );
      expect(planEventIntent(waiting, 'hover.enter'), const EventIntentPlanAcceptNoop());
      expect(
        planEventIntent(waiting, 'load'),
        EventIntentPlanReplacePending(_edge(indexes, 'idle-loading')),
      );
    });

    test('cancels a preparation or intro route through its inverse event', () {
      for (final phase in [MotionGraphPhase.preparing, MotionGraphPhase.intro]) {
        expect(
          planEventIntent(_context(indexes, phase, pending: _edge(indexes, 'idle-hover')), 'hover.leave'),
          EventIntentPlanCancelPending(_edge(indexes, 'hover-idle')),
        );
      }
    });

    test('commits a direct event immediately in static mode', () {
      expect(
        planEventIntent(_context(indexes, MotionGraphPhase.static), 'idle.error'),
        EventIntentPlanStaticCommit(_edge(indexes, 'idle-error')),
      );
    });

    test('treats locked and reversible event routing symmetrically', () {
      final cases = [
        (
          phase: MotionGraphPhase.locked,
          active: _edge(indexes, 'idle-loading'),
          activeEvent: 'load',
          followOn: _edge(indexes, 'loading-success'),
          followOnEvent: 'loading.success',
        ),
        (
          phase: MotionGraphPhase.reversible,
          active: _edge(indexes, 'idle-hover'),
          activeEvent: 'hover.enter',
          followOn: _edge(indexes, 'hover-success'),
          followOnEvent: 'hover.success',
        ),
      ];

      for (final c in cases) {
        final active = _context(indexes, c.phase, active: c.active);
        expect(planEventIntent(active, c.activeEvent), const EventIntentPlanAcceptNoop());
        expect(
          planEventIntent(active, c.followOnEvent),
          EventIntentPlanQueueFollowOn(c.followOn),
        );

        final queued = _context(indexes, c.phase, active: c.active, followOn: c.followOn);
        expect(planEventIntent(queued, c.followOnEvent), const EventIntentPlanAcceptNoop());
        expect(
          planEventIntent(queued, c.activeEvent),
          EventIntentPlanContinueActiveTarget(c.active),
        );
      }
    });

    test('queues an inverse event only while the reversible edge is active', () {
      expect(
        planEventIntent(
          _context(indexes, MotionGraphPhase.reversible, active: _edge(indexes, 'idle-hover')),
          'hover.leave',
        ),
        EventIntentPlanQueueReversal(_edge(indexes, 'hover-idle')),
      );

      expect(
        planEventIntent(
          _context(indexes, MotionGraphPhase.locked, active: _edge(indexes, 'idle-loading')),
          'hover.leave',
        ),
        const EventIntentPlanReject(),
      );
    });

    test('uses active and effective targets when reversal and follow-on are queued', () {
      final reversing = _context(
        indexes,
        MotionGraphPhase.reversible,
        active: _edge(indexes, 'idle-hover'),
        reversal: _edge(indexes, 'hover-idle'),
        followOn: _edge(indexes, 'idle-error'),
      );

      // Reiterating the queued inverse is actionable because it cancels the
      // follow-on when the engine applies this plan.
      expect(
        planEventIntent(reversing, 'hover.leave'),
        EventIntentPlanQueueReversal(_edge(indexes, 'hover-idle')),
      );
      // The active edge's own trigger remains reachable and cancels both queues.
      expect(
        planEventIntent(reversing, 'hover.enter'),
        EventIntentPlanContinueActiveTarget(_edge(indexes, 'idle-hover')),
      );
      expect(planEventIntent(reversing, 'idle.error'), const EventIntentPlanAcceptNoop());

      // Event lookup must not extend from either the old active target or the
      // queued follow-on target, which would create an invalid multi-hop route.
      expect(planEventIntent(reversing, 'hover.success'), const EventIntentPlanReject());
      expect(planEventIntent(reversing, 'error.done'), const EventIntentPlanReject());
    });

    test('rejects missing events', () {
      expect(planEventIntent(_context(indexes, MotionGraphPhase.stable), 'missing'), const EventIntentPlanReject());
    });

    test('throws on structurally impossible waiting and active phases', () {
      expect(
        () => planEventIntent(_context(indexes, MotionGraphPhase.waiting), 'hover.enter'),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('graph invariant missing waiting pending edge'),
        )),
      );
      expect(
        () => planStateIntent(_context(indexes, MotionGraphPhase.reversible), 'hover'),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('graph invariant missing active transition edge'),
        )),
      );
    });
  });
}

class _TestRouteView implements RoutePlanView {
  _TestRouteView({this.pending, this.active, this.reversal, this.followOn});

  @override
  final SequencedEdge? pending;
  @override
  final SequencedEdge? active;
  @override
  final SequencedEdge? reversal;
  @override
  final SequencedEdge? followOn;

  @override
  SequencedEdge? recoveryCandidate() => followOn ?? reversal ?? active ?? pending;

  @override
  GraphStateId? prospectiveState(GraphStateId? visualState) =>
      followOn?.edge.to ?? reversal?.edge.to ?? active?.edge.to ?? pending?.edge.to ?? visualState;

  @override
  bool hasRoute() => pending != null || active != null || reversal != null || followOn != null;
}

IntentContext _context(
  ValidatedGraphIndexes indexes,
  MotionGraphPhase phase, {
  GraphEdgeDefinition? pending,
  GraphEdgeDefinition? active,
  GraphEdgeDefinition? followOn,
  GraphEdgeDefinition? reversal,
  bool hasPendingRequests = false,
}) {
  return IntentContext(
    phase: phase,
    visualState: 'idle',
    routes: _TestRouteView(
      pending: pending == null ? null : SequencedEdge(edge: pending, sequence: 1),
      active: active == null ? null : SequencedEdge(edge: active, sequence: 2),
      reversal: reversal == null ? null : SequencedEdge(edge: reversal, sequence: 3),
      followOn: followOn == null ? null : SequencedEdge(edge: followOn, sequence: 4),
    ),
    indexes: indexes,
    hasPendingRequests: hasPendingRequests,
  );
}

GraphEdgeDefinition _edge(ValidatedGraphIndexes indexes, String id) {
  final found = indexes.edgesById[id];
  if (found == null) throw StateError('missing fixture edge $id');
  return found;
}

Map<String, Object?> _graph() {
  return {
    'initialState': 'idle',
    'states': [
      for (final id in ['idle', 'hover', 'loading', 'success', 'error', 'done']) _state(id),
    ],
    'edges': [
      _reversibleEdge('idle-hover', 'idle', 'hover', 'forward', 'hover.enter'),
      _reversibleEdge('hover-idle', 'hover', 'idle', 'reverse', 'hover.leave', reverseOf: 'idle-hover'),
      _lockedEdge('idle-loading', 'idle', 'loading', 'load'),
      _cutEdge('idle-error', 'idle', 'error', 'idle.error'),
      _cutEdge('hover-success', 'hover', 'success', 'hover.success'),
      _cutEdge('loading-success', 'loading', 'success', 'loading.success'),
      _cutEdge('error-done', 'error', 'done', 'error.done'),
    ],
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
        {'id': 'handoff', 'entryFrame': 0, 'portalFrames': [0, 1]},
      ],
    },
  };
}

Map<String, Object?> _reversibleEdge(
  String id,
  String from,
  String to,
  String direction,
  String event, {
  String? reverseOf,
}) {
  final transition = <String, Object?>{
    'kind': 'reversible',
    'unitId': 'hover-motion',
    'frameCount': 3,
    'direction': direction,
  };
  if (reverseOf != null) transition['reverseOf'] = reverseOf;
  return {
    'id': id,
    'from': from,
    'to': to,
    'trigger': {'type': 'event', 'name': event},
    'start': {'type': 'portal', 'sourcePort': 'handoff', 'targetPort': 'handoff', 'maxWaitFrames': 1},
    'transition': transition,
    'continuity': reverseOf == null ? 'exact-authored' : 'exact-reverse',
  };
}

Map<String, Object?> _lockedEdge(String id, String from, String to, String event) {
  return {
    'id': id,
    'from': from,
    'to': to,
    'trigger': {'type': 'event', 'name': event},
    'start': {'type': 'portal', 'sourcePort': 'handoff', 'targetPort': 'handoff', 'maxWaitFrames': 1},
    'transition': {'kind': 'locked', 'unitId': 'loading-motion', 'frameCount': 2},
    'continuity': 'exact-authored',
  };
}

Map<String, Object?> _cutEdge(String id, String from, String to, String event) {
  return {
    'id': id,
    'from': from,
    'to': to,
    'trigger': {'type': 'event', 'name': event},
    'start': {'type': 'cut', 'targetPort': 'handoff', 'maxWaitFrames': 1},
    'continuity': 'cut',
  };
}
