/// Pending-route identity, boundary reconciliation, and wait accounting.
///
/// Direct port of `packages/player-web/src/runtime/path-scheduler-route.ts`.
/// `SubmissionHorizonDecision`'s `kind === "select-portal"` discriminant maps
/// onto `decision is SubmissionHorizonSelectPortal`. `ScheduledPathRoute` is
/// reused from `path_sequence.dart`. `Object.freeze`d routes are stored
/// directly (immutable value objects here).
library;

import 'package:aval_graph/aval_graph.dart';

import 'path_sequence.dart' show ScheduledPathRoute;
import 'submission_horizon.dart';

/// Inputs for [PathSchedulerRoute.decide].
class PathSchedulerRouteDecisionInput {
  const PathSchedulerRouteDecisionInput({
    required this.body,
    required this.displayed,
    required this.submitted,
    required this.ringCapacity,
    required this.availableConsecutiveEdgeFrames,
  });

  final GraphBodyDefinition body;
  final SourceBodyCursor displayed;
  final SourceBodyCursor submitted;
  final int ringCapacity;
  final int availableConsecutiveEdgeFrames;
}

/// Owns pending-route identity, boundary reconciliation, and wait accounting.
class PathSchedulerRoute {
  ScheduledPathRoute? _current;
  bool _committed = false;
  int _elapsedWaitFrames = 0;

  ScheduledPathRoute? get current => _current;

  bool get committed => _committed;

  String? get pendingEdge => _current?.edge.id;

  SubmissionHorizonDecision decide(
    GraphEdgeDefinition edge,
    PathSchedulerRouteDecisionInput input,
  ) {
    return planSubmissionHorizon(SubmissionHorizonInput(
      body: input.body,
      edge: edge,
      displayed: input.displayed,
      submitted: input.submitted,
      ringCapacity: input.ringCapacity,
      availableConsecutiveEdgeFrames: input.availableConsecutiveEdgeFrames,
      elapsedWaitFrames: _elapsedWaitFrames,
    ));
  }

  void prepare({
    required GraphEdgeDefinition edge,
    required String targetState,
    required GraphBodyDefinition targetBody,
    required SourceBoundary boundary,
  }) {
    _current = ScheduledPathRoute(
      edge: edge,
      targetState: targetState,
      targetBody: targetBody,
      boundary: boundary,
    );
    _committed = false;
    _elapsedWaitFrames = 0;
  }

  SourceBoundary? reconcileBoundary(
    SubmissionHorizonDecision decision,
    bool edgeSubmissionStarted,
  ) {
    final route = _current;
    if (route == null ||
        decision is! SubmissionHorizonSelectPortal ||
        _sameBoundary(decision.boundary, route.boundary)) {
      return null;
    }
    if (edgeSubmissionStarted) {
      throw RangeError(
        'prepared edge lead cannot move after edge submission began',
      );
    }
    _current = ScheduledPathRoute(
      edge: route.edge,
      targetState: route.targetState,
      targetBody: route.targetBody,
      boundary: decision.boundary,
    );
    return decision.boundary;
  }

  void commit() {
    if (_current == null) {
      throw RangeError('path scheduler has no route to commit');
    }
    _committed = true;
  }

  void noteDisplayedSource() {
    if (_current != null) _elapsedWaitFrames += 1;
  }

  void clear() {
    _current = null;
    _committed = false;
    _elapsedWaitFrames = 0;
  }

  void activateResident() {
    _current = null;
    _committed = true;
    _elapsedWaitFrames = 0;
  }
}

bool _sameBoundary(SourceBoundary left, SourceBoundary right) {
  return left.occurrence == right.occurrence && left.frame == right.frame;
}
