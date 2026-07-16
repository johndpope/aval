/// Cursor identity/freeze helpers for the path scheduler.
///
/// Direct port of `packages/player-web/src/runtime/path-scheduler-identity.ts`.
/// The TS helpers `Object.freeze` a shallow clone; `RuntimeMediaCursor` and
/// `SourceBodyCursor` are already immutable value types here, so the "freeze"
/// helpers return their argument unchanged (a documented, behavior-identical
/// no-op — no consumer mutates the returned cursor).
library;

import 'model.dart';
import 'submission_horizon.dart' show SourceBodyCursor;

RuntimeMediaCursor schedulerMediaCursor(RuntimeMediaPresentationFrame media) {
  return RuntimeMediaCursor(
    path: media.path,
    unit: media.frame.unit,
    unitInstance: media.unitInstance,
    localFrame: media.frame.localFrame,
  );
}

RuntimeMediaCursor? freezeSchedulerCursor(RuntimeMediaCursor? cursor) {
  return cursor;
}

SourceBodyCursor? freezeSchedulerSourceCursor(SourceBodyCursor? cursor) {
  return cursor;
}
