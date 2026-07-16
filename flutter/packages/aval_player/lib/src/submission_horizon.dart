/// Pure owner of selected-route source horizon and boundary decisions.
///
/// Direct port of `packages/player-web/src/runtime/submission-horizon.ts`.
/// TypeScript `bigint` occurrence/absolute arithmetic becomes Dart `BigInt`;
/// `number` counters become `int`. The `SourceBoundary.type` string union
/// becomes the [SourceBoundaryType] enum — its wire values are compared
/// lexicographically (via [SourceBoundaryType.wireValue]) exactly where the TS
/// tie-break did `boundary.type < earliest.type`. The
/// `SubmissionHorizonDecision` discriminated union becomes a sealed-class
/// hierarchy, each carrying the same `kind` wire string.
///
/// The `GraphStartPolicy`/`GraphTransition` discriminants (`type === "cut"`
/// etc.) map onto the `aval_graph` sealed subclasses (`GraphStartPolicyCut`,
/// `GraphTransitionReversible`, ...). `validateBody`'s unreachable
/// "kind is invalid" branch (submission-horizon.ts:495) is dropped: `body.kind`
/// is a closed `GraphBodyKind` enum in the Dart port and cannot be invalid.
library;

import 'package:aval_graph/aval_graph.dart';

import 'edge_lead.dart';
import 'presentation_ring.dart';

/// A cursor into one occurrence of a source body.
class SourceBodyCursor {
  const SourceBodyCursor({required this.occurrence, required this.frame});

  final BigInt occurrence;
  final int frame;

  @override
  bool operator ==(Object other) =>
      other is SourceBodyCursor &&
      other.occurrence == occurrence &&
      other.frame == frame;

  @override
  int get hashCode => Object.hash(occurrence, frame);

  @override
  String toString() =>
      'SourceBodyCursor(occurrence: $occurrence, frame: $frame)';
}

/// The category of a resolved source boundary.
enum SourceBoundaryType {
  portal('portal'),
  finish('finish'),
  cut('cut');

  const SourceBoundaryType(this.wireValue);

  final String wireValue;
}

/// A resolved source boundary the selected route may depart at.
class SourceBoundary {
  const SourceBoundary({
    required this.type,
    required this.occurrence,
    required this.frame,
    required this.wraps,
  });

  final SourceBoundaryType type;
  final BigInt occurrence;
  final int frame;
  final bool wraps;

  @override
  bool operator ==(Object other) =>
      other is SourceBoundary &&
      other.type == type &&
      other.occurrence == occurrence &&
      other.frame == frame &&
      other.wraps == wraps;

  @override
  int get hashCode => Object.hash(type, occurrence, frame, wraps);

  @override
  String toString() =>
      'SourceBoundary(type: $type, occurrence: $occurrence, frame: $frame, '
      'wraps: $wraps)';
}

/// Reason a selected-portal decision resolved as it did.
enum SelectPortalReason {
  authoredBoundary('authored-boundary'),
  submittedHorizon('submitted-horizon'),
  leadUnavailable('lead-unavailable');

  const SelectPortalReason(this.wireValue);

  final String wireValue;
}

/// Reason a readiness rejection resolved as it did.
enum RejectReadinessReason {
  maxWaitExceeded('max-wait-exceeded'),
  noReachableBoundary('no-reachable-boundary');

  const RejectReadinessReason(this.wireValue);

  final String wireValue;
}

/// Selected-route submission-horizon input.
class SubmissionHorizonInput {
  const SubmissionHorizonInput({
    required this.body,
    required this.edge,
    required this.displayed,
    required this.submitted,
    required this.ringCapacity,
    required this.availableConsecutiveEdgeFrames,
    required this.elapsedWaitFrames,
  });

  final GraphBodyDefinition body;
  final GraphEdgeDefinition edge;
  final SourceBodyCursor displayed;

  /// Furthest source access unit already submitted, inclusive.
  final SourceBodyCursor submitted;
  final int ringCapacity;
  final int availableConsecutiveEdgeFrames;

  /// Content ticks already charged to this request.
  final int elapsedWaitFrames;
}

/// The pure decision returned by [planSubmissionHorizon].
sealed class SubmissionHorizonDecision {
  const SubmissionHorizonDecision();

  String get kind;
}

class SubmissionHorizonContinueSource extends SubmissionHorizonDecision {
  const SubmissionHorizonContinueSource({
    required this.boundary,
    required this.waitFrames,
    required this.totalWaitFrames,
    required this.lead,
  });

  final SourceBoundary boundary;
  final int waitFrames;
  final int totalWaitFrames;
  final EdgeLeadPlan? lead;

  @override
  String get kind => 'continue-source';
}

class SubmissionHorizonSelectPortal extends SubmissionHorizonDecision {
  const SubmissionHorizonSelectPortal({
    required this.reason,
    required this.boundary,
    required this.waitFrames,
    required this.totalWaitFrames,
    required this.lead,
  });

  final SelectPortalReason reason;
  final SourceBoundary boundary;
  final int waitFrames;
  final int totalWaitFrames;
  final EdgeLeadPlan? lead;

  @override
  String get kind => 'select-portal';
}

class SubmissionHorizonWaitHeld extends SubmissionHorizonDecision {
  const SubmissionHorizonWaitHeld({
    required this.boundary,
    required this.elapsedWaitFrames,
    required this.remainingWaitFrames,
    required this.lead,
  });

  final SourceBoundary boundary;
  final int elapsedWaitFrames;
  final int remainingWaitFrames;
  final EdgeLeadPlan lead;

  @override
  String get kind => 'wait-held';
}

class SubmissionHorizonCommitEdge extends SubmissionHorizonDecision {
  const SubmissionHorizonCommitEdge({
    required this.boundary,
    required this.totalWaitFrames,
    required this.lead,
  });

  final SourceBoundary boundary;
  final int totalWaitFrames;
  final EdgeLeadPlan? lead;

  @override
  String get kind => 'commit-edge';
}

class SubmissionHorizonRestartGeneration extends SubmissionHorizonDecision {
  const SubmissionHorizonRestartGeneration({required this.totalWaitFrames});

  /// Always `"cut"`.
  final String reason = 'cut';

  /// Always `1`.
  final int responseFrames = 1;
  final int totalWaitFrames;

  @override
  String get kind => 'restart-generation';
}

class SubmissionHorizonRejectReadiness extends SubmissionHorizonDecision {
  const SubmissionHorizonRejectReadiness({
    required this.reason,
    required this.requiredWaitFrames,
    required this.maxWaitFrames,
    required this.lead,
  });

  final RejectReadinessReason reason;
  final BigInt requiredWaitFrames;
  final int maxWaitFrames;
  final EdgeLeadPlan? lead;

  @override
  String get kind => 'reject-readiness';
}

/// Unresolved-route submission-horizon input.
class UnresolvedSubmissionHorizonInput {
  const UnresolvedSubmissionHorizonInput({
    required this.body,
    required this.displayed,
    required this.submitted,
    required this.outgoingStarts,
    required this.ringCapacity,
  });

  final GraphBodyDefinition body;
  final SourceBodyCursor displayed;
  final SourceBodyCursor submitted;
  final List<GraphStartPolicy> outgoingStarts;
  final int ringCapacity;
}

/// The pure result returned by [planUnresolvedSubmissionHorizon].
class UnresolvedSubmissionHorizon {
  const UnresolvedSubmissionHorizon({
    required this.earliestBoundary,
    required this.maximumSubmitted,
    required this.submittedWithinHorizon,
    required this.framesBeyondEarliestBoundary,
  });

  final SourceBoundary earliestBoundary;
  final SourceBodyCursor maximumSubmitted;
  final bool submittedWithinHorizon;
  final BigInt framesBeyondEarliestBoundary;

  @override
  bool operator ==(Object other) =>
      other is UnresolvedSubmissionHorizon &&
      other.earliestBoundary == earliestBoundary &&
      other.maximumSubmitted == maximumSubmitted &&
      other.submittedWithinHorizon == submittedWithinHorizon &&
      other.framesBeyondEarliestBoundary == framesBeyondEarliestBoundary;

  @override
  int get hashCode => Object.hash(
        earliestBoundary,
        maximumSubmitted,
        submittedWithinHorizon,
        framesBeyondEarliestBoundary,
      );

  @override
  String toString() =>
      'UnresolvedSubmissionHorizon(earliestBoundary: $earliestBoundary, '
      'maximumSubmitted: $maximumSubmitted, '
      'submittedWithinHorizon: $submittedWithinHorizon, '
      'framesBeyondEarliestBoundary: $framesBeyondEarliestBoundary)';
}

/// Free-running source submission may pass the earliest unresolved boundary by
/// at most one presentation-ring capacity.
UnresolvedSubmissionHorizon planUnresolvedSubmissionHorizon(
  UnresolvedSubmissionHorizonInput input,
) {
  validatePresentationRingCapacity(input.ringCapacity);
  _validateBody(input.body);
  _validateCursor(input.body, input.displayed, 'displayed cursor');
  _validateCursor(input.body, input.submitted, 'submitted cursor');
  final displayedAbsolute = _cursorAbsolute(
    input.body,
    input.displayed.occurrence,
    input.displayed.frame,
  );
  final submittedAbsolute = _cursorAbsolute(
    input.body,
    input.submitted.occurrence,
    input.submitted.frame,
  );
  if (submittedAbsolute < displayedAbsolute) {
    throw RangeError('submitted cursor cannot be behind displayed cursor');
  }
  if (input.outgoingStarts.isEmpty) {
    throw RangeError('unresolved horizon requires an outgoing start policy');
  }

  SourceBoundary? earliest;
  BigInt? earliestAbsolute;
  for (final start in input.outgoingStarts) {
    final boundary = _boundaryForStart(input.body, input.displayed, start);
    final absolute =
        _cursorAbsolute(input.body, boundary.occurrence, boundary.frame);
    if (earliestAbsolute == null ||
        absolute < earliestAbsolute ||
        absolute == earliestAbsolute &&
            boundary.type.wireValue.compareTo(earliest!.type.wireValue) < 0) {
      earliest = boundary;
      earliestAbsolute = absolute;
    }
  }
  if (earliest == null || earliestAbsolute == null) {
    throw RangeError('unresolved horizon has no reachable boundary');
  }

  var maximumAbsolute = earliestAbsolute + BigInt.from(input.ringCapacity);
  if (input.body.kind != GraphBodyKind.loop) {
    maximumAbsolute = _minimumBigInt(
      maximumAbsolute,
      BigInt.from(input.body.frameCount - 1),
    );
  }
  final framesBeyondEarliestBoundary = submittedAbsolute > earliestAbsolute
      ? submittedAbsolute - earliestAbsolute
      : BigInt.zero;
  return UnresolvedSubmissionHorizon(
    earliestBoundary: earliest,
    maximumSubmitted: _cursorFromAbsolute(input.body, maximumAbsolute),
    submittedWithinHorizon: submittedAbsolute <= maximumAbsolute,
    framesBeyondEarliestBoundary: framesBeyondEarliestBoundary,
  );
}

/// Sole pure owner of selected-route source horizon and boundary decisions.
SubmissionHorizonDecision planSubmissionHorizon(SubmissionHorizonInput input) {
  validatePresentationRingCapacity(input.ringCapacity);
  _validateBody(input.body);
  _validateCursor(input.body, input.displayed, 'displayed cursor');
  _validateCursor(input.body, input.submitted, 'submitted cursor');
  _validateNonNegativeSafeInteger(
    input.elapsedWaitFrames,
    'elapsed wait frame count',
  );
  _validateNonNegativeSafeInteger(
    input.edge.start.maxWaitFrames,
    'edge maxWaitFrames',
  );
  _validateNonNegativeSafeInteger(
    input.availableConsecutiveEdgeFrames,
    'available consecutive frame count',
  );
  if (input.availableConsecutiveEdgeFrames > input.ringCapacity) {
    throw RangeError(
      'available consecutive frame count exceeds the presentation ring',
    );
  }

  final displayedAbsolute = _cursorAbsolute(
    input.body,
    input.displayed.occurrence,
    input.displayed.frame,
  );
  final submittedAbsolute = _cursorAbsolute(
    input.body,
    input.submitted.occurrence,
    input.submitted.frame,
  );
  if (submittedAbsolute < displayedAbsolute) {
    throw RangeError('submitted cursor cannot be behind displayed cursor');
  }
  final maxWaitFrames = input.edge.start.maxWaitFrames;
  final elapsed = BigInt.from(input.elapsedWaitFrames);

  if (input.edge.start is GraphStartPolicyCut) {
    final totalWait = elapsed + BigInt.one;
    if (totalWait > BigInt.from(maxWaitFrames)) {
      return _rejectMaxWait(totalWait, maxWaitFrames, null);
    }
    return SubmissionHorizonRestartGeneration(
      totalWaitFrames: totalWait.toInt(),
    );
  }

  final lead = _createLeadPlan(input);
  if (input.edge.start is GraphStartPolicyFinish) {
    return _planFinish(
      body: input.body,
      displayed: input.displayed,
      elapsed: elapsed,
      maxWaitFrames: maxWaitFrames,
      lead: lead,
    );
  }

  final start = input.edge.start as GraphStartPolicyPortal;
  return _planPortal(
    body: input.body,
    sourcePort: start.sourcePort,
    displayed: input.displayed,
    displayedAbsolute: displayedAbsolute,
    submittedAbsolute: submittedAbsolute,
    elapsed: elapsed,
    maxWaitFrames: maxWaitFrames,
    lead: lead,
  );
}

SubmissionHorizonDecision _planFinish({
  required GraphBodyDefinition body,
  required SourceBodyCursor displayed,
  required BigInt elapsed,
  required int maxWaitFrames,
  required EdgeLeadPlan? lead,
}) {
  final search = findFinishBoundary(body, displayed.frame);
  final boundary = SourceBoundary(
    type: SourceBoundaryType.finish,
    occurrence: displayed.occurrence,
    frame: search.boundaryFrame,
    wraps: false,
  );
  final wait = BigInt.from(search.waitFrames);
  final totalWait = elapsed + wait;
  if (totalWait > BigInt.from(maxWaitFrames)) {
    return _rejectMaxWait(totalWait, maxWaitFrames, lead);
  }
  if (wait > BigInt.zero) {
    return SubmissionHorizonContinueSource(
      boundary: boundary,
      waitFrames: wait.toInt(),
      totalWaitFrames: totalWait.toInt(),
      lead: lead,
    );
  }
  if (_leadReady(lead)) {
    return SubmissionHorizonCommitEdge(
      boundary: boundary,
      totalWaitFrames: totalWait.toInt(),
      lead: lead,
    );
  }
  if (lead == null) {
    throw StateError('resident edge lead invariant failed');
  }
  if (elapsed >= BigInt.from(maxWaitFrames)) {
    return _rejectMaxWait(elapsed + BigInt.one, maxWaitFrames, lead);
  }
  return SubmissionHorizonWaitHeld(
    boundary: boundary,
    elapsedWaitFrames: elapsed.toInt(),
    remainingWaitFrames: maxWaitFrames - elapsed.toInt(),
    lead: lead,
  );
}

SubmissionHorizonDecision _planPortal({
  required GraphBodyDefinition body,
  required String sourcePort,
  required SourceBodyCursor displayed,
  required BigInt displayedAbsolute,
  required BigInt submittedAbsolute,
  required BigInt elapsed,
  required int maxWaitFrames,
  required EdgeLeadPlan? lead,
}) {
  final graphSearch = findNextPortalBoundary(body, sourcePort, displayed.frame);
  final graphBoundaryOccurrence =
      displayed.occurrence + (graphSearch.wraps ? BigInt.one : BigInt.zero);
  final graphBoundaryAbsolute =
      graphBoundaryOccurrence * BigInt.from(body.frameCount) +
          BigInt.from(graphSearch.boundaryFrame);

  // A reversible transition is already resident (`lead == null`), so source
  // frames submitted beyond the visible authored portal can be discarded.
  // Streamed transitions still have to select at/after their submitted debt.
  final minimumAbsolute = lead == null
      ? displayedAbsolute
      : _maximumBigInt(displayedAbsolute, submittedAbsolute);
  var candidate = _findPortalAtOrAfter(
    body,
    sourcePort,
    minimumAbsolute,
    displayed.occurrence,
  );
  if (candidate == null) {
    return _rejectNoBoundary(maxWaitFrames, lead);
  }

  var reason = candidate.absolute > graphBoundaryAbsolute
      ? SelectPortalReason.submittedHorizon
      : SelectPortalReason.authoredBoundary;

  if (candidate.absolute == displayedAbsolute && _leadReady(lead)) {
    if (elapsed > BigInt.from(maxWaitFrames)) {
      return _rejectMaxWait(elapsed, maxWaitFrames, lead);
    }
    return SubmissionHorizonCommitEdge(
      boundary: candidate.boundary,
      totalWaitFrames: elapsed.toInt(),
      lead: lead,
    );
  }

  if (candidate.absolute == displayedAbsolute) {
    final later = _findPortalAtOrAfter(
      body,
      sourcePort,
      displayedAbsolute + BigInt.one,
      displayed.occurrence,
    );
    if (later == null) {
      if (body.kind != GraphBodyKind.loop &&
          displayed.frame == body.frameCount - 1 &&
          lead != null) {
        if (elapsed >= BigInt.from(maxWaitFrames)) {
          return _rejectMaxWait(elapsed + BigInt.one, maxWaitFrames, lead);
        }
        return SubmissionHorizonWaitHeld(
          boundary: candidate.boundary,
          elapsedWaitFrames: elapsed.toInt(),
          remainingWaitFrames: maxWaitFrames - elapsed.toInt(),
          lead: lead,
        );
      }
      return _rejectNoBoundary(maxWaitFrames, lead);
    }
    candidate = later;
    reason = SelectPortalReason.leadUnavailable;
  }

  final wait = candidate.absolute - displayedAbsolute;
  final totalWait = elapsed + wait;
  if (totalWait > BigInt.from(maxWaitFrames)) {
    return _rejectMaxWait(totalWait, maxWaitFrames, lead);
  }
  return SubmissionHorizonSelectPortal(
    reason: reason,
    boundary: candidate.boundary,
    waitFrames: wait.toInt(),
    totalWaitFrames: totalWait.toInt(),
    lead: lead,
  );
}

EdgeLeadPlan? _createLeadPlan(SubmissionHorizonInput input) {
  final transition = input.edge.transition;
  if (transition is GraphTransitionReversible) {
    return null;
  }
  return planEdgeLead(EdgeLeadInput(
    transitionFrames: transition?.frameCount ?? 0,
    ringCapacity: input.ringCapacity,
    availableConsecutiveFrames: input.availableConsecutiveEdgeFrames,
  ));
}

bool _leadReady(EdgeLeadPlan? lead) {
  return lead == null || lead.ready;
}

SourceBoundary _boundaryForStart(
  GraphBodyDefinition body,
  SourceBodyCursor displayed,
  GraphStartPolicy start,
) {
  if (start is GraphStartPolicyCut) {
    return SourceBoundary(
      type: SourceBoundaryType.cut,
      occurrence: displayed.occurrence,
      frame: displayed.frame,
      wraps: false,
    );
  }
  if (start is GraphStartPolicyFinish) {
    final search = findFinishBoundary(body, displayed.frame);
    return SourceBoundary(
      type: SourceBoundaryType.finish,
      occurrence: displayed.occurrence,
      frame: search.boundaryFrame,
      wraps: false,
    );
  }
  final portalStart = start as GraphStartPolicyPortal;
  final search =
      findNextPortalBoundary(body, portalStart.sourcePort, displayed.frame);
  return SourceBoundary(
    type: SourceBoundaryType.portal,
    occurrence: displayed.occurrence + (search.wraps ? BigInt.one : BigInt.zero),
    frame: search.boundaryFrame,
    wraps: search.wraps,
  );
}

class _PortalCandidate {
  const _PortalCandidate({required this.absolute, required this.boundary});

  final BigInt absolute;
  final SourceBoundary boundary;
}

_PortalCandidate? _findPortalAtOrAfter(
  GraphBodyDefinition body,
  String sourcePort,
  BigInt minimumAbsolute,
  BigInt displayedOccurrence,
) {
  // Invoke graph's owner first for complete body/port geometry validation.
  findNextPortalBoundary(body, sourcePort, 0);
  GraphPortDefinition? port;
  for (final candidate in body.ports) {
    if (candidate.id == sourcePort) {
      port = candidate;
      break;
    }
  }
  if (port == null) {
    return null;
  }

  final frameCount = BigInt.from(body.frameCount);
  if (body.kind != GraphBodyKind.loop) {
    final minimumFrame = minimumAbsolute.toInt();
    final frame = _firstFrameAtOrAfter(port.portalFrames, minimumFrame);
    if (frame == null) {
      return null;
    }
    return _PortalCandidate(
      absolute: BigInt.from(frame),
      boundary: SourceBoundary(
        type: SourceBoundaryType.portal,
        occurrence: BigInt.zero,
        frame: frame,
        wraps: false,
      ),
    );
  }

  var occurrence = minimumAbsolute ~/ frameCount;
  final minimumFrame = (minimumAbsolute % frameCount).toInt();
  int? frame = _firstFrameAtOrAfter(port.portalFrames, minimumFrame);
  if (frame == null) {
    occurrence += BigInt.one;
    frame = port.portalFrames.isEmpty ? null : port.portalFrames[0];
  }
  if (frame == null) {
    return null;
  }
  final absolute = occurrence * frameCount + BigInt.from(frame);
  return _PortalCandidate(
    absolute: absolute,
    boundary: SourceBoundary(
      type: SourceBoundaryType.portal,
      occurrence: occurrence,
      frame: frame,
      wraps: occurrence > displayedOccurrence,
    ),
  );
}

int? _firstFrameAtOrAfter(List<int> portalFrames, int minimumFrame) {
  for (final portal in portalFrames) {
    if (portal >= minimumFrame) {
      return portal;
    }
  }
  return null;
}

void _validateBody(GraphBodyDefinition body) {
  if (body.frameCount <= 0) {
    throw RangeError('source body frameCount must be a positive safe integer');
  }
  if (body.kind == GraphBodyKind.held && body.frameCount != 1) {
    throw RangeError('held source body must contain one frame');
  }
}

void _validateCursor(
  GraphBodyDefinition body,
  SourceBodyCursor cursor,
  String label,
) {
  if (cursor.occurrence < BigInt.zero) {
    throw RangeError('$label occurrence must be a non-negative bigint');
  }
  if (cursor.frame < 0 || cursor.frame >= body.frameCount) {
    throw RangeError('$label frame is out of range');
  }
  if (body.kind != GraphBodyKind.loop && cursor.occurrence != BigInt.zero) {
    throw RangeError('$label must remain in occurrence zero');
  }
}

BigInt _cursorAbsolute(GraphBodyDefinition body, BigInt occurrence, int frame) {
  return occurrence * BigInt.from(body.frameCount) + BigInt.from(frame);
}

SourceBodyCursor _cursorFromAbsolute(GraphBodyDefinition body, BigInt absolute) {
  if (body.kind != GraphBodyKind.loop) {
    return SourceBodyCursor(occurrence: BigInt.zero, frame: absolute.toInt());
  }
  final frameCount = BigInt.from(body.frameCount);
  return SourceBodyCursor(
    occurrence: absolute ~/ frameCount,
    frame: (absolute % frameCount).toInt(),
  );
}

SubmissionHorizonRejectReadiness _rejectMaxWait(
  BigInt requiredWaitFrames,
  int maxWaitFrames,
  EdgeLeadPlan? lead,
) {
  return SubmissionHorizonRejectReadiness(
    reason: RejectReadinessReason.maxWaitExceeded,
    requiredWaitFrames: requiredWaitFrames,
    maxWaitFrames: maxWaitFrames,
    lead: lead,
  );
}

SubmissionHorizonRejectReadiness _rejectNoBoundary(
  int maxWaitFrames,
  EdgeLeadPlan? lead,
) {
  return SubmissionHorizonRejectReadiness(
    reason: RejectReadinessReason.noReachableBoundary,
    requiredWaitFrames: BigInt.from(maxWaitFrames) + BigInt.one,
    maxWaitFrames: maxWaitFrames,
    lead: lead,
  );
}

void _validateNonNegativeSafeInteger(int value, String label) {
  if (value < 0) {
    throw RangeError('$label must be a non-negative safe integer');
  }
}

BigInt _maximumBigInt(BigInt left, BigInt right) {
  return left > right ? left : right;
}

BigInt _minimumBigInt(BigInt left, BigInt right) {
  return left < right ? left : right;
}
