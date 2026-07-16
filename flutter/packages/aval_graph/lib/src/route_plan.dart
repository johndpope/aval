/// Route topology owner, ported from `packages/graph/src/route-plan.ts`.
///
/// Every value here is immutable by construction (`final` fields, no
/// setters), which is the Dart equivalent of the TypeScript source calling
/// `Object.freeze()` on each returned value — so this port has no runtime
/// "is frozen" checks to make, unlike the TypeScript test suite which
/// verifies `Object.isFrozen(...)` defensively.
library;

import 'model.dart';

/// An authored edge and the input sequence which selected it.
class SequencedEdge {
  const SequencedEdge({required this.edge, required this.sequence});

  final GraphEdgeDefinition edge;
  final int sequence;

  @override
  bool operator ==(Object other) =>
      other is SequencedEdge && other.edge == edge && other.sequence == sequence;

  @override
  int get hashCode => Object.hash(edge, sequence);

  @override
  String toString() => 'SequencedEdge(edge: ${edge.id}, sequence: $sequence)';
}

/// Read-only route topology consumed by intent routing and snapshots.
///
/// The slot priority is significant: a follow-on is the final prospective
/// destination, followed by a queued reversal, the active edge, and finally a
/// pending edge waiting for its authored departure boundary.
abstract interface class RoutePlanView {
  SequencedEdge? get pending;
  SequencedEdge? get active;
  SequencedEdge? get followOn;
  SequencedEdge? get reversal;

  SequencedEdge? recoveryCandidate();
  GraphStateId? prospectiveState(GraphStateId? visualState);
  bool hasRoute();
}

class ActiveRouteCompletion {
  const ActiveRouteCompletion({required this.completed, this.promoted});

  final SequencedEdge completed;
  final SequencedEdge? promoted;
}

class RoutePlanCheckpoint {
  const RoutePlanCheckpoint({this.pending, this.active, this.followOn, this.reversal});

  final SequencedEdge? pending;
  final SequencedEdge? active;
  final SequencedEdge? followOn;
  final SequencedEdge? reversal;
}

/// Owns the engine's small route plan and its cross-slot mutations.
///
/// Graph lookup remains outside this class. Callers supply validated edges;
/// [RoutePlan] keeps each edge and its selecting sequence in one immutable
/// value so the two cannot drift apart during promotion or reversal.
class RoutePlan implements RoutePlanView {
  SequencedEdge? _pending;
  SequencedEdge? _active;
  SequencedEdge? _followOn;
  SequencedEdge? _reversal;

  @override
  SequencedEdge? get pending => _pending;

  @override
  SequencedEdge? get active => _active;

  @override
  SequencedEdge? get followOn => _followOn;

  @override
  SequencedEdge? get reversal => _reversal;

  /// Replace a waiting route and discard queued continuations.
  SequencedEdge replacePending(GraphEdgeDefinition edge, int sequence) {
    if (_active != null) {
      throw StateError(
        'an active route must complete or clear before replacement',
      );
    }
    final pending = _freezeSequencedEdge(edge, sequence);
    _pending = pending;
    _followOn = null;
    _reversal = null;
    return pending;
  }

  /// Cancel only the edge which is still waiting to depart.
  SequencedEdge? cancelPending() {
    final cancelled = _pending;
    _pending = null;
    return cancelled;
  }

  /// Make an edge active. A matching pending slot is consumed atomically;
  /// completion edges may activate directly when there is no pending slot.
  SequencedEdge activate(GraphEdgeDefinition edge, int sequence) {
    if (_active != null) {
      throw StateError('a route is already active');
    }
    final currentPending = _pending;
    if (currentPending != null &&
        (currentPending.edge.id != edge.id ||
            currentPending.sequence != sequence)) {
      throw StateError('activated route does not match the pending route');
    }
    if (_followOn != null || _reversal != null) {
      throw StateError('queued routes require an active route');
    }

    final active = currentPending ?? _freezeSequencedEdge(edge, sequence);
    _pending = null;
    _active = active;
    return active;
  }

  /// Queue or replace the one direct continuation after the effective edge.
  SequencedEdge queueFollowOn(GraphEdgeDefinition edge, int sequence) {
    final active = _requireActive();
    final effective = _reversal ?? active;
    if (edge.from != effective.edge.to) {
      throw StateError(
        'follow-on source must match the effective route target',
      );
    }
    final followOn = _freezeSequencedEdge(edge, sequence);
    _followOn = followOn;
    return followOn;
  }

  SequencedEdge? clearFollowOn() {
    final cleared = _followOn;
    _followOn = null;
    return cleared;
  }

  /// Queue an inverse edge and cancel any continuation it supersedes.
  SequencedEdge queueReversal(GraphEdgeDefinition edge, int sequence) {
    final active = _requireActive();
    if (edge.from != active.edge.to || edge.to != active.edge.from) {
      throw StateError('reversal must invert the active route');
    }
    final reversal = _freezeSequencedEdge(edge, sequence);
    _followOn = null;
    _reversal = reversal;
    return reversal;
  }

  SequencedEdge? clearReversal() {
    final cleared = _reversal;
    _reversal = null;
    return cleared;
  }

  /// Promote a queued reversal to active without disturbing its follow-on.
  SequencedEdge activateReversal() {
    _requireActive();
    final reversal = _reversal;
    if (reversal == null) {
      throw StateError('route plan has no queued reversal');
    }
    _active = reversal;
    _reversal = null;
    return reversal;
  }

  /// Complete the active edge and promote its continuation to pending.
  ActiveRouteCompletion completeActive() {
    final completed = _requireActive();
    final currentFollowOn = _followOn;
    if (currentFollowOn != null && currentFollowOn.edge.from != completed.edge.to) {
      throw StateError(
        'follow-on source must match the completed route target',
      );
    }

    final promoted = currentFollowOn;
    _active = null;
    _reversal = null;
    _followOn = null;
    _pending = promoted;
    return ActiveRouteCompletion(completed: completed, promoted: promoted);
  }

  /// Select the authored route which best represents recovery intent.
  @override
  SequencedEdge? recoveryCandidate() =>
      _followOn ?? _reversal ?? _active ?? _pending;

  /// Return the final state implied by the current route topology.
  @override
  GraphStateId? prospectiveState(GraphStateId? visualState) =>
      _followOn?.edge.to ??
      _reversal?.edge.to ??
      _active?.edge.to ??
      _pending?.edge.to ??
      visualState;

  @override
  bool hasRoute() =>
      _pending != null || _active != null || _followOn != null || _reversal != null;

  void clear() {
    _pending = null;
    _active = null;
    _followOn = null;
    _reversal = null;
  }

  RoutePlanCheckpoint checkpoint() => RoutePlanCheckpoint(
        pending: _pending,
        active: _active,
        followOn: _followOn,
        reversal: _reversal,
      );

  void restore(RoutePlanCheckpoint checkpoint) {
    _pending = checkpoint.pending;
    _active = checkpoint.active;
    _followOn = checkpoint.followOn;
    _reversal = checkpoint.reversal;
  }

  SequencedEdge _requireActive() {
    final active = _active;
    if (active == null) {
      throw StateError('route plan has no active route');
    }
    return active;
  }
}

SequencedEdge _freezeSequencedEdge(GraphEdgeDefinition edge, int sequence) {
  if (sequence < 0) {
    throw RangeError('route sequence must be a non-negative safe integer');
  }
  return SequencedEdge(edge: edge, sequence: sequence);
}
