/// Runtime presentation/scheduler data types referenced by the path scheduler.
///
/// **Partial port** of `packages/player-web/src/runtime/model.ts`. Only the
/// shapes the path-scheduler family references — [RuntimeFrameKey],
/// [RuntimeMediaPresentation], [RuntimeMediaCursor], [RuntimeSchedulerSnapshot]
/// — are ported here as frozen types. The rest of the runtime model (readiness,
/// failures, trace records, candidate reports, `summarizeStaticReason`, ...) is
/// a later phase's responsibility and will extend this file.
///
/// The `RuntimeMediaPresentation` discriminated union becomes a sealed-class
/// hierarchy. The `graphKind: Exclude<GraphPresentation["kind"], "static">`
/// field becomes the [RuntimeMediaGraphKind] enum; the `drawSource` string
/// unions become the [RuntimeMediaDrawSource] enum (and the fixed
/// `"fallback"` literal on the static variant).
library;

/// Stable authored identity. Equal pixels never merge different keys.
class RuntimeFrameKey {
  const RuntimeFrameKey({
    required this.rendition,
    required this.unit,
    required this.localFrame,
  });

  final String rendition;
  final String unit;
  final int localFrame;

  @override
  bool operator ==(Object other) =>
      other is RuntimeFrameKey &&
      other.rendition == rendition &&
      other.unit == unit &&
      other.localFrame == localFrame;

  @override
  int get hashCode => Object.hash(rendition, unit, localFrame);

  @override
  String toString() =>
      'RuntimeFrameKey(rendition: $rendition, unit: $unit, '
      'localFrame: $localFrame)';
}

/// The non-static graph presentation kinds a media frame can carry
/// (`Exclude<GraphPresentation["kind"], "static">`).
enum RuntimeMediaGraphKind {
  intro('intro'),
  body('body'),
  locked('locked'),
  reversible('reversible');

  const RuntimeMediaGraphKind(this.wireValue);

  final String wireValue;
}

/// Where a media frame's pixels are drawn from.
enum RuntimeMediaDrawSource {
  resident('resident'),
  streaming('streaming');

  const RuntimeMediaDrawSource(this.wireValue);

  final String wireValue;
}

/// What the runtime is presenting right now.
sealed class RuntimeMediaPresentation {
  const RuntimeMediaPresentation();

  String get kind;
}

/// A static (fallback poster) presentation.
class RuntimeMediaPresentationStatic extends RuntimeMediaPresentation {
  const RuntimeMediaPresentationStatic({required this.state});

  final String state;

  /// Always `"fallback"`.
  final String drawSource = 'fallback';

  @override
  String get kind => 'static';
}

/// A decoded-frame presentation.
class RuntimeMediaPresentationFrame extends RuntimeMediaPresentation {
  const RuntimeMediaPresentationFrame({
    required this.graphKind,
    required this.state,
    required this.edge,
    required this.path,
    required this.frame,
    required this.drawSource,
    required this.generation,
    required this.unitInstance,
    required this.decodeOrdinal,
    required this.timestamp,
    required this.intendedPresentationOrdinal,
  });

  final RuntimeMediaGraphKind graphKind;
  final String? state;
  final String? edge;
  final String path;
  final RuntimeFrameKey frame;
  final RuntimeMediaDrawSource drawSource;
  final int generation;
  final int unitInstance;
  final int decodeOrdinal;
  final int timestamp;
  final BigInt intendedPresentationOrdinal;

  @override
  String get kind => 'frame';
}

/// A cursor into a rendition/unit/frame the runtime tracks.
class RuntimeMediaCursor {
  const RuntimeMediaCursor({
    required this.path,
    required this.unit,
    required this.unitInstance,
    required this.localFrame,
  });

  final String path;
  final String unit;
  final int unitInstance;
  final int localFrame;

  @override
  bool operator ==(Object other) =>
      other is RuntimeMediaCursor &&
      other.path == path &&
      other.unit == unit &&
      other.unitInstance == unitInstance &&
      other.localFrame == localFrame;

  @override
  int get hashCode => Object.hash(path, unit, unitInstance, localFrame);

  @override
  String toString() =>
      'RuntimeMediaCursor(path: $path, unit: $unit, '
      'unitInstance: $unitInstance, localFrame: $localFrame)';
}

/// Observable scheduler cursors and ring occupancy.
class RuntimeSchedulerSnapshot {
  const RuntimeSchedulerSnapshot({
    required this.generation,
    required this.activePath,
    required this.sourceCursor,
    required this.submittedCursor,
    required this.decodedCursor,
    required this.displayedCursor,
    required this.ringSize,
    required this.ringCapacity,
    required this.smoothSession,
  });

  final int? generation;
  final String? activePath;
  final RuntimeMediaCursor? sourceCursor;
  final RuntimeMediaCursor? submittedCursor;
  final RuntimeMediaCursor? decodedCursor;
  final RuntimeMediaCursor? displayedCursor;
  final int ringSize;
  final int ringCapacity;
  final bool smoothSession;
}
