/// Canonical source identity and decode/presentation cursor ledger.
///
/// Direct port of `packages/player-web/src/runtime/path-scheduler-cursor-ledger.ts`.
/// The TS `PathSchedulerSourceReplacement` discriminated union becomes a
/// sealed-class hierarchy; `bigint` ordinals become `BigInt`. The TS `snapshot`
/// record becomes [PathSchedulerCursorLedgerSnapshot]. Defensive cursor clones
/// (`{ ...cursor }`) are pass-throughs — `SourceBodyCursor`/`RuntimeMediaCursor`
/// are immutable value types.
library;

import 'package:aval_graph/aval_graph.dart';

import 'model.dart';
import 'path_scheduler_identity.dart';
import 'path_scheduler_output.dart'
    show PathSchedulerExpectedOutput, PathSchedulerOutputDrainReport;
import 'path_sequence.dart';
import 'submission_horizon.dart' show SourceBodyCursor;

/// How a generation replacement reseeds the source cursor ledger.
sealed class PathSchedulerSourceReplacement {
  const PathSchedulerSourceReplacement();
}

class PathSchedulerSourceReplacementRouteRestart
    extends PathSchedulerSourceReplacement {
  const PathSchedulerSourceReplacementRouteRestart({
    required this.checkpoint,
    required this.firstPresentationOrdinal,
  });

  final SourceBodyCursor checkpoint;
  final BigInt firstPresentationOrdinal;
}

class PathSchedulerSourceReplacementResidentCheckpoint
    extends PathSchedulerSourceReplacement {
  const PathSchedulerSourceReplacementResidentCheckpoint({
    required this.state,
    required this.body,
    required this.outgoingStarts,
    required this.frame,
    required this.unitInstance,
    required this.presentationOrdinal,
    required this.path,
  });

  final String state;
  final GraphBodyDefinition body;
  final List<GraphStartPolicy> outgoingStarts;
  final int frame;
  final int unitInstance;
  final BigInt presentationOrdinal;
  final String path;
}

class PathSchedulerSourceReplacementResidentRunway
    extends PathSchedulerSourceReplacement {
  const PathSchedulerSourceReplacementResidentRunway({
    required this.targetState,
    required this.targetBody,
    required this.runwayFrames,
    required this.firstPresentationOrdinal,
  });

  final String targetState;
  final GraphBodyDefinition targetBody;
  final int runwayFrames;
  final BigInt firstPresentationOrdinal;
}

/// The read-only projection [PathSchedulerCursorLedger.snapshot] returns.
class PathSchedulerCursorLedgerSnapshot {
  const PathSchedulerCursorLedgerSnapshot({
    required this.sourceCursor,
    required this.submittedCursor,
    required this.decodedCursor,
    required this.displayedCursor,
    required this.submittedSource,
    required this.displayedSource,
  });

  final RuntimeMediaCursor? sourceCursor;
  final RuntimeMediaCursor? submittedCursor;
  final RuntimeMediaCursor? decodedCursor;
  final RuntimeMediaCursor? displayedCursor;
  final SourceBodyCursor? submittedSource;
  final SourceBodyCursor? displayedSource;
}

/// Canonical source identity and decode/presentation cursor ledger. Every
/// generation replacement resets this state through [replaceSource].
class PathSchedulerCursorLedger {
  String? _sourceState;
  GraphBodyDefinition? _sourceBody;
  List<GraphStartPolicy> _outgoingStarts = const <GraphStartPolicy>[];
  SourceBodyCursor? _submittedSource;
  SourceBodyCursor? _decodedSource;
  SourceBodyCursor? _displayedSource;
  SourceBodyCursor? _submittedTarget;
  SourceBodyCursor? _decodedTarget;
  SourceBodyCursor? _displayedTarget;
  RuntimeMediaCursor? _submittedCursor;
  RuntimeMediaCursor? _decodedCursor;
  RuntimeMediaCursor? _displayedCursor;
  BigInt? _lastDisplayedOrdinal;

  String? get sourceState => _sourceState;

  GraphBodyDefinition? get sourceBody => _sourceBody;

  List<GraphStartPolicy> get outgoingStarts => _outgoingStarts;

  SourceBodyCursor? get submittedSource => _submittedSource;

  SourceBodyCursor? get decodedSource => _decodedSource;

  SourceBodyCursor? get displayedSource => _displayedSource;

  SourceBodyCursor? get submittedTarget => _submittedTarget;

  SourceBodyCursor? get decodedTarget => _decodedTarget;

  SourceBodyCursor? get displayedTarget => _displayedTarget;

  BigInt? get lastDisplayedOrdinal => _lastDisplayedOrdinal;

  PathSequenceState startSource({
    required String state,
    required GraphBodyDefinition body,
    required List<GraphStartPolicy> outgoingStarts,
    required BigInt firstPresentationOrdinal,
  }) {
    _sourceState = state;
    _sourceBody = body;
    _outgoingStarts = List<GraphStartPolicy>.unmodifiable(outgoingStarts);
    return createSourcePathSequence(firstPresentationOrdinal);
  }

  PathSequenceState replaceSource(PathSchedulerSourceReplacement input) {
    switch (input) {
      case PathSchedulerSourceReplacementRouteRestart():
        return _replaceRouteSource(input);
      case PathSchedulerSourceReplacementResidentCheckpoint():
        return _replaceResidentCheckpoint(input);
      case PathSchedulerSourceReplacementResidentRunway():
        return _replaceResidentRunway(input);
    }
  }

  void recordSubmitted(
    List<PathSchedulerExpectedOutput> outputs,
    String path,
  ) {
    for (final output in outputs) {
      _submittedCursor = RuntimeMediaCursor(
        path: path,
        unit: output.sample.unitId,
        unitInstance: output.sample.unitInstance,
        localFrame: output.sample.unitFrame,
      );
      if (output.plan.sourceCursor != null && !output.plan.discard) {
        _submittedSource = output.plan.sourceCursor;
      }
      if (output.plan.targetCursor != null && !output.plan.discard) {
        _submittedTarget = output.plan.targetCursor;
      }
    }
  }

  void recordDrain(PathSchedulerOutputDrainReport report) {
    if (report.decodedCursor != null) {
      _decodedCursor = report.decodedCursor;
    }
    if (report.decodedSource != null) {
      _decodedSource = report.decodedSource;
    }
    if (report.decodedTarget != null) {
      _decodedTarget = report.decodedTarget;
    }
  }

  /// Returns true when route wait accounting must advance.
  bool recordDisplayed(
    PathSchedulerExpectedOutput output,
    RuntimeMediaPresentationFrame media,
  ) {
    _displayedCursor = schedulerMediaCursor(media);
    _lastDisplayedOrdinal = media.intendedPresentationOrdinal;
    var displayedSource = false;
    if (output.plan.sourceCursor != null) {
      _displayedSource = output.plan.sourceCursor;
      displayedSource = true;
    }
    if (output.plan.targetCursor != null) {
      _displayedTarget = output.plan.targetCursor;
    }
    return displayedSource;
  }

  void recordResidentDisplayed(RuntimeMediaPresentationFrame media) {
    _lastDisplayedOrdinal = media.intendedPresentationOrdinal;
    _displayedCursor = schedulerMediaCursor(media);
  }

  void recordHeld(BigInt ordinal) {
    if (ordinal < BigInt.zero || _displayedSource == null) {
      throw RangeError('scheduler held presentation is invalid');
    }
    _lastDisplayedOrdinal = ordinal;
  }

  void promoteTargetToSource({
    required String state,
    required GraphBodyDefinition body,
    required List<GraphStartPolicy> outgoingStarts,
  }) {
    final displayed = _displayedTarget;
    if (displayed == null) {
      throw RangeError('scheduler has no displayed target to promote');
    }
    _sourceState = state;
    _sourceBody = body;
    _outgoingStarts = List<GraphStartPolicy>.unmodifiable(outgoingStarts);
    _submittedSource = _promotedSourceCursor(
      _submittedTarget ?? displayed,
      body,
    );
    _decodedSource = _promotedSourceCursor(
      _decodedTarget ?? displayed,
      body,
    );
    _displayedSource = _promotedSourceCursor(displayed, body);
    _submittedTarget = null;
    _decodedTarget = null;
    _displayedTarget = null;
  }

  PathSchedulerCursorLedgerSnapshot snapshot() {
    return PathSchedulerCursorLedgerSnapshot(
      sourceCursor: _displayedSource == null || _sourceBody == null
          ? null
          : RuntimeMediaCursor(
              path: _displayedCursor?.path ?? '',
              unit: _sourceBody!.unitId,
              unitInstance: _displayedCursor?.unitInstance ?? 0,
              localFrame: _displayedSource!.frame,
            ),
      submittedCursor: freezeSchedulerCursor(_submittedCursor),
      decodedCursor: freezeSchedulerCursor(_decodedCursor),
      displayedCursor: freezeSchedulerCursor(_displayedCursor),
      submittedSource: freezeSchedulerSourceCursor(_submittedSource),
      displayedSource: freezeSchedulerSourceCursor(_displayedSource),
    );
  }

  PathSequenceState _replaceRouteSource(
    PathSchedulerSourceReplacementRouteRestart input,
  ) {
    final body = _sourceBody;
    if (body == null) {
      throw RangeError('route replacement has no source body');
    }
    final checkpoint = input.checkpoint;
    final next = nextBodyCursor(body, checkpoint);
    _submittedSource = checkpoint;
    _decodedSource = checkpoint;
    _submittedTarget = null;
    _decodedTarget = null;
    _displayedTarget = null;
    _submittedCursor = null;
    _decodedCursor = null;
    if (next == null) {
      final terminal = createSourcePathSequence(input.firstPresentationOrdinal);
      terminal.sourceNext = null;
      return terminal;
    }
    return createReplacementPathSequence(
      nextSource: next,
      firstPresentationOrdinal: input.firstPresentationOrdinal,
    );
  }

  PathSequenceState _replaceResidentCheckpoint(
    PathSchedulerSourceReplacementResidentCheckpoint input,
  ) {
    final displayed =
        SourceBodyCursor(occurrence: BigInt.zero, frame: input.frame);
    final next = nextBodyCursor(input.body, displayed);
    _sourceState = input.state;
    _sourceBody = input.body;
    _outgoingStarts = List<GraphStartPolicy>.unmodifiable(input.outgoingStarts);
    _submittedSource = displayed;
    _decodedSource = displayed;
    _displayedSource = displayed;
    _submittedTarget = null;
    _decodedTarget = null;
    _displayedTarget = null;
    _submittedCursor = null;
    _decodedCursor = null;
    _displayedCursor = RuntimeMediaCursor(
      path: input.path,
      unit: input.body.unitId,
      unitInstance: input.unitInstance,
      localFrame: input.frame,
    );
    _lastDisplayedOrdinal = input.presentationOrdinal;
    if (next == null) {
      final terminal =
          createSourcePathSequence(input.presentationOrdinal + BigInt.one);
      terminal.sourceNext = null;
      return terminal;
    }
    return createReplacementPathSequence(
      nextSource: next,
      firstPresentationOrdinal: input.presentationOrdinal + BigInt.one,
    );
  }

  PathSequenceState _replaceResidentRunway(
    PathSchedulerSourceReplacementResidentRunway input,
  ) {
    _sourceState = input.targetState;
    _sourceBody = input.targetBody;
    _outgoingStarts = const <GraphStartPolicy>[];
    _submittedSource = null;
    _decodedSource = null;
    _displayedSource = null;
    _submittedTarget = null;
    _decodedTarget = null;
    _displayedTarget = null;
    _submittedCursor = null;
    _decodedCursor = null;
    return createResidentContinuationSequence(
      runwayFrames: input.runwayFrames,
      targetBody: input.targetBody,
      firstStreamingPresentationOrdinal:
          input.firstPresentationOrdinal + BigInt.from(input.runwayFrames),
    );
  }
}

SourceBodyCursor _promotedSourceCursor(
  SourceBodyCursor cursor,
  GraphBodyDefinition body,
) {
  return SourceBodyCursor(
    occurrence:
        body.kind == GraphBodyKind.loop ? cursor.occurrence : BigInt.zero,
    frame: cursor.frame,
  );
}
