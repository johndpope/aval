/// Frame-by-frame path sequence builder shared by the path scheduler.
///
/// Direct port of `packages/player-web/src/runtime/path-sequence.ts`.
/// TypeScript `bigint` presentation ordinals/occurrences become Dart `BigInt`;
/// `number` frame counters become `int`. The `phase` and `graphKind` string
/// unions become the [PathSequencePhase] / [PathFrameGraphKind] enums. The
/// `GraphTransition.kind === "locked"` discriminant maps onto the `aval_graph`
/// `GraphTransitionLocked` subclass. `Object.freeze` on emitted plans becomes
/// immutable value classes (`SourceBodyCursor` is already immutable, so the
/// TS defensive cursor clone in `freezePathFramePlan` is a pass-through here).
library;

import 'dart:math' as math;

import 'package:aval_graph/aval_graph.dart';

import 'path_scheduler_model.dart' show PathSchedulerFramePurpose;
import 'submission_horizon.dart' show SourceBodyCursor, SourceBoundary;

/// Which graph object a planned frame belongs to.
enum PathFrameGraphKind {
  body('body'),
  locked('locked');

  const PathFrameGraphKind(this.wireValue);

  final String wireValue;
}

/// Phase of a [PathSequenceState].
enum PathSequencePhase {
  source,
  bridge,
  target,
  done;
}

/// A fully-resolved route the sequence departs onto.
class ScheduledPathRoute {
  const ScheduledPathRoute({
    required this.edge,
    required this.targetState,
    required this.targetBody,
    required this.boundary,
  });

  final GraphEdgeDefinition edge;
  final String targetState;
  final GraphBodyDefinition targetBody;
  final SourceBoundary boundary;
}

/// A resident (already-decoded) runway target.
class ResidentPathTarget {
  const ResidentPathTarget({
    required this.edgeId,
    required this.targetState,
    required this.targetBody,
  });

  final String edgeId;
  final String targetState;
  final GraphBodyDefinition targetBody;
}

/// Mutable cursor/phase state advanced by [buildNextPathFrame].
class PathSequenceState {
  PathSequenceState({
    required this.phase,
    required this.sourceNext,
    required this.sourceStop,
    required this.sourceDiscardBefore,
    required this.bridgeNextFrame,
    required this.targetNext,
    required this.targetDiscardRemaining,
    required this.nextPresentationOrdinal,
    required this.edgeSubmissionStarted,
  });

  PathSequencePhase phase;
  SourceBodyCursor? sourceNext;
  SourceBodyCursor? sourceStop;
  SourceBodyCursor? sourceDiscardBefore;
  int bridgeNextFrame;
  SourceBodyCursor? targetNext;
  int targetDiscardRemaining;
  BigInt nextPresentationOrdinal;
  bool edgeSubmissionStarted;
}

/// One planned decode frame.
class PathFramePlan {
  const PathFramePlan({
    required this.purpose,
    required this.unitId,
    required this.unitFrame,
    required this.state,
    required this.edge,
    required this.graphKind,
    required this.sourceCursor,
    required this.targetCursor,
    required this.discard,
    required this.intendedPresentationOrdinal,
  });

  final PathSchedulerFramePurpose purpose;
  final String unitId;
  final int unitFrame;
  final String? state;
  final String? edge;
  final PathFrameGraphKind graphKind;
  final SourceBodyCursor? sourceCursor;
  final SourceBodyCursor? targetCursor;
  final bool discard;
  final BigInt? intendedPresentationOrdinal;
}

/// Read-only context for one [buildNextPathFrame] step.
class PathSequenceContext {
  const PathSequenceContext({
    required this.sourceState,
    required this.sourceBody,
    required this.route,
    required this.residentTarget,
    required this.canSubmitSource,
  });

  final String? sourceState;
  final GraphBodyDefinition? sourceBody;
  final ScheduledPathRoute? route;
  final ResidentPathTarget? residentTarget;
  final bool Function(SourceBodyCursor cursor) canSubmitSource;
}

PathSequenceState createSourcePathSequence(BigInt firstPresentationOrdinal) {
  return PathSequenceState(
    phase: PathSequencePhase.source,
    sourceNext: SourceBodyCursor(occurrence: BigInt.zero, frame: 0),
    sourceStop: null,
    sourceDiscardBefore: null,
    bridgeNextFrame: 0,
    targetNext: null,
    targetDiscardRemaining: 0,
    nextPresentationOrdinal: firstPresentationOrdinal,
    edgeSubmissionStarted: false,
  );
}

PathSequenceState createReplacementPathSequence({
  required SourceBodyCursor nextSource,
  required BigInt firstPresentationOrdinal,
}) {
  return PathSequenceState(
    phase: PathSequencePhase.source,
    sourceNext: SourceBodyCursor(occurrence: nextSource.occurrence, frame: 0),
    sourceStop: null,
    sourceDiscardBefore: SourceBodyCursor(
      occurrence: nextSource.occurrence,
      frame: nextSource.frame,
    ),
    bridgeNextFrame: 0,
    targetNext: null,
    targetDiscardRemaining: 0,
    nextPresentationOrdinal: firstPresentationOrdinal,
    edgeSubmissionStarted: false,
  );
}

PathSequenceState createResidentContinuationSequence({
  required int runwayFrames,
  required GraphBodyDefinition targetBody,
  required BigInt firstStreamingPresentationOrdinal,
}) {
  return PathSequenceState(
    phase: PathSequencePhase.target,
    sourceNext: null,
    sourceStop: null,
    sourceDiscardBefore: null,
    bridgeNextFrame: 0,
    targetNext: SourceBodyCursor(occurrence: BigInt.zero, frame: 0),
    targetDiscardRemaining: targetBody.kind == GraphBodyKind.loop
        ? runwayFrames
        : math.min(runwayFrames, targetBody.frameCount - 1),
    nextPresentationOrdinal: firstStreamingPresentationOrdinal,
    edgeSubmissionStarted: false,
  );
}

PathSequenceState clonePathSequenceState(PathSequenceState state) {
  return PathSequenceState(
    phase: state.phase,
    sourceNext: _cloneSourceCursor(state.sourceNext),
    sourceStop: _cloneSourceCursor(state.sourceStop),
    sourceDiscardBefore: _cloneSourceCursor(state.sourceDiscardBefore),
    bridgeNextFrame: state.bridgeNextFrame,
    targetNext: _cloneSourceCursor(state.targetNext),
    targetDiscardRemaining: state.targetDiscardRemaining,
    nextPresentationOrdinal: state.nextPresentationOrdinal,
    edgeSubmissionStarted: state.edgeSubmissionStarted,
  );
}

PathFramePlan? buildNextPathFrame(
  PathSequenceState state,
  PathSequenceContext context,
) {
  while (true) {
    if (state.phase == PathSequencePhase.source) {
      final body = context.sourceBody;
      final current = state.sourceNext;
      if (body == null) {
        state.phase = PathSequencePhase.done;
        continue;
      }
      if (current == null) {
        if (context.route != null && state.sourceStop != null) {
          _switchToEdge(state, context.route);
        } else {
          state.phase = PathSequencePhase.done;
        }
        continue;
      }
      if (state.sourceStop != null &&
          _compareSourceCursor(body, current, state.sourceStop!) > 0) {
        _switchToEdge(state, context.route);
        continue;
      }
      final discard = state.sourceDiscardBefore != null &&
          _compareSourceCursor(body, current, state.sourceDiscardBefore!) < 0;
      if (context.route == null &&
          !discard &&
          !context.canSubmitSource(current)) {
        return null;
      }
      final intended = discard ? null : state.nextPresentationOrdinal;
      if (!discard) state.nextPresentationOrdinal += BigInt.one;
      final plan = _freezePathFramePlan(PathFramePlan(
        purpose: PathSchedulerFramePurpose.source,
        unitId: body.unitId,
        unitFrame: current.frame,
        state: context.sourceState,
        edge: null,
        graphKind: PathFrameGraphKind.body,
        sourceCursor: current,
        targetCursor: null,
        discard: discard,
        intendedPresentationOrdinal: intended,
      ));
      state.sourceNext = nextBodyCursor(body, current);
      return plan;
    }

    if (state.phase == PathSequencePhase.bridge) {
      final route = context.route;
      final transition = route?.edge.transition;
      if (route == null || transition is! GraphTransitionLocked) {
        state.phase = PathSequencePhase.target;
        continue;
      }
      if (state.bridgeNextFrame >= transition.frameCount) {
        state.phase = PathSequencePhase.target;
        state.targetNext = SourceBodyCursor(occurrence: BigInt.zero, frame: 0);
        continue;
      }
      final frame = state.bridgeNextFrame;
      state.bridgeNextFrame += 1;
      final intended = state.nextPresentationOrdinal;
      state.nextPresentationOrdinal += BigInt.one;
      state.edgeSubmissionStarted = true;
      return _freezePathFramePlan(PathFramePlan(
        purpose: PathSchedulerFramePurpose.bridge,
        unitId: transition.unitId,
        unitFrame: frame,
        state: null,
        edge: route.edge.id,
        graphKind: PathFrameGraphKind.locked,
        sourceCursor: null,
        targetCursor: null,
        discard: false,
        intendedPresentationOrdinal: intended,
      ));
    }

    if (state.phase == PathSequencePhase.target) {
      final route = context.route;
      final ResidentPathTarget? target = route == null
          ? context.residentTarget
          : ResidentPathTarget(
              edgeId: route.edge.id,
              targetState: route.targetState,
              targetBody: route.targetBody,
            );
      final cursor = state.targetNext;
      if (target == null || cursor == null) {
        state.phase = PathSequencePhase.done;
        continue;
      }
      final discard = state.targetDiscardRemaining > 0;
      if (discard) state.targetDiscardRemaining -= 1;
      final intended = discard ? null : state.nextPresentationOrdinal;
      if (!discard) state.nextPresentationOrdinal += BigInt.one;
      final plan = _freezePathFramePlan(PathFramePlan(
        purpose: PathSchedulerFramePurpose.target,
        unitId: target.targetBody.unitId,
        unitFrame: cursor.frame,
        state: target.targetState,
        edge: target.edgeId,
        graphKind: PathFrameGraphKind.body,
        sourceCursor: null,
        targetCursor: cursor,
        discard: discard,
        intendedPresentationOrdinal: intended,
      ));
      state.targetNext = nextBodyCursor(target.targetBody, cursor);
      if (state.targetNext == null) {
        if (target.targetBody.frameCount == 1) {
          state.targetNext = SourceBodyCursor(
            occurrence: cursor.occurrence + BigInt.one,
            frame: 0,
          );
        } else {
          state.phase = PathSequencePhase.done;
        }
      }
      return plan;
    }

    return null;
  }
}

SourceBodyCursor? nextBodyCursor(
  GraphBodyDefinition body,
  SourceBodyCursor cursor,
) {
  if (body.kind == GraphBodyKind.loop) {
    return cursor.frame + 1 < body.frameCount
        ? SourceBodyCursor(occurrence: cursor.occurrence, frame: cursor.frame + 1)
        : SourceBodyCursor(occurrence: cursor.occurrence + BigInt.one, frame: 0);
  }
  return cursor.frame + 1 < body.frameCount
      ? SourceBodyCursor(occurrence: BigInt.zero, frame: cursor.frame + 1)
      : null;
}

void promoteTargetSequenceToSource(
  PathSequenceState state,
  GraphBodyDefinition body,
) {
  if (state.phase != PathSequencePhase.target &&
      state.phase != PathSequencePhase.done) {
    throw RangeError('only a target sequence can become a source sequence');
  }
  // A finite target may already be fully prefetched. Keep a terminal source
  // phase so a completion/finish route can still switch at exhaustion.
  state.phase = PathSequencePhase.source;
  state.sourceNext = body.kind == GraphBodyKind.loop
      ? _cloneSourceCursor(state.targetNext)
      : body.kind == GraphBodyKind.finite && state.targetNext != null
          ? SourceBodyCursor(
              occurrence: BigInt.zero,
              frame: state.targetNext!.frame,
            )
          : null;
  state.sourceStop = null;
  state.sourceDiscardBefore = null;
  state.targetNext = null;
  state.targetDiscardRemaining = 0;
  state.edgeSubmissionStarted = false;
}

bool sameSourceCursor(SourceBodyCursor left, SourceBodyCursor right) {
  return left.occurrence == right.occurrence && left.frame == right.frame;
}

void _switchToEdge(PathSequenceState state, ScheduledPathRoute? route) {
  final transition = route?.edge.transition;
  if (transition is GraphTransitionLocked) {
    state.phase = PathSequencePhase.bridge;
    state.bridgeNextFrame = 0;
    return;
  }
  state.phase = PathSequencePhase.target;
  state.targetNext = SourceBodyCursor(occurrence: BigInt.zero, frame: 0);
}

int _compareSourceCursor(
  GraphBodyDefinition body,
  SourceBodyCursor left,
  SourceBodyCursor right,
) {
  final frameCount = BigInt.from(body.frameCount);
  final leftAbsolute = left.occurrence * frameCount + BigInt.from(left.frame);
  final rightAbsolute = right.occurrence * frameCount + BigInt.from(right.frame);
  return leftAbsolute < rightAbsolute
      ? -1
      : leftAbsolute > rightAbsolute
          ? 1
          : 0;
}

SourceBodyCursor? _cloneSourceCursor(SourceBodyCursor? cursor) {
  return cursor == null
      ? null
      : SourceBodyCursor(occurrence: cursor.occurrence, frame: cursor.frame);
}

PathFramePlan _freezePathFramePlan(PathFramePlan plan) {
  return PathFramePlan(
    purpose: plan.purpose,
    unitId: plan.unitId,
    unitFrame: plan.unitFrame,
    state: plan.state,
    edge: plan.edge,
    graphKind: plan.graphKind,
    sourceCursor: plan.sourceCursor == null
        ? null
        : SourceBodyCursor(
            occurrence: plan.sourceCursor!.occurrence,
            frame: plan.sourceCursor!.frame,
          ),
    targetCursor: plan.targetCursor == null
        ? null
        : SourceBodyCursor(
            occurrence: plan.targetCursor!.occurrence,
            frame: plan.targetCursor!.frame,
          ),
    discard: plan.discard,
    intendedPresentationOrdinal: plan.intendedPresentationOrdinal,
  );
}
