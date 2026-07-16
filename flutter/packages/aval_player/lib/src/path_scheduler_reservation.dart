/// The scheduler's sole draw-barrier presentation reservation.
///
/// Direct port of `packages/player-web/src/runtime/path-scheduler-reservation.ts`.
/// `PathSchedulerFrameMedia` (the TS `Extract<RuntimeMediaPresentation,
/// {kind:"frame"}>`) is [RuntimeMediaPresentationFrame]. `Object.freeze`d
/// reservations are stored directly (the reservation and its media are
/// immutable value objects here).
library;

import 'model.dart';
import 'path_scheduler_output.dart' show PathSchedulerExpectedOutput;

/// The frame-kind media a reservation carries.
typedef PathSchedulerFrameMedia = RuntimeMediaPresentationFrame;

/// One prepared, not-yet-committed presentation.
class PathSchedulerPresentationReservation {
  const PathSchedulerPresentationReservation({
    required this.media,
    required this.output,
    required this.commitRoute,
  });

  final PathSchedulerFrameMedia media;
  final PathSchedulerExpectedOutput? output;
  final bool commitRoute;
}

/// Owns the scheduler's sole draw-barrier presentation reservation.
class PathSchedulerReservationOwner {
  PathSchedulerPresentationReservation? _current;

  PathSchedulerPresentationReservation? get current => _current;

  void reserve(PathSchedulerPresentationReservation reservation) {
    requireEmpty();
    _current = reservation;
  }

  PathSchedulerPresentationReservation consume(PathSchedulerFrameMedia media) {
    final current = _current;
    if (current == null || !sameSchedulerMediaIdentity(current.media, media)) {
      throw RangeError('scheduler presentation reservation diverged');
    }
    _current = null;
    return current;
  }

  void discard() {
    _current = null;
  }

  void requireEmpty() {
    if (_current != null) {
      throw RangeError('scheduler already has a prepared presentation');
    }
  }
}

bool sameSchedulerMediaIdentity(
  PathSchedulerFrameMedia left,
  PathSchedulerFrameMedia right,
) {
  return left.graphKind == right.graphKind &&
      left.state == right.state &&
      left.edge == right.edge &&
      left.path == right.path &&
      left.frame.rendition == right.frame.rendition &&
      left.frame.unit == right.frame.unit &&
      left.frame.localFrame == right.frame.localFrame &&
      left.unitInstance == right.unitInstance &&
      left.decodeOrdinal == right.decodeOrdinal &&
      left.timestamp == right.timestamp &&
      left.intendedPresentationOrdinal == right.intendedPresentationOrdinal;
}
