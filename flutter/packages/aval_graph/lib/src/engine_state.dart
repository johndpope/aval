/// Package-private mechanical storage for the canonical graph reducer,
/// ported from `packages/graph/src/engine-state.ts`.
library;

import 'errors.dart';
import 'model.dart';
import 'operation_journal.dart';
import 'request_ledger.dart';
import 'route_plan.dart';
import 'validate.dart';

class MotionGraphEngineCheckpoint {
  const MotionGraphEngineCheckpoint({
    required this.readiness,
    required this.phase,
    required this.initialUnitPending,
    required this.requestedState,
    required this.visualState,
    required this.presentation,
    required this.ledger,
    required this.journal,
    required this.routes,
  });

  final MotionGraphReadiness readiness;
  final MotionGraphPhase phase;
  final bool initialUnitPending;
  final GraphStateId? requestedState;
  final GraphStateId? visualState;
  final GraphPresentation? presentation;
  final RequestLedgerCheckpoint ledger;
  final OperationJournalCheckpoint journal;
  final RoutePlanCheckpoint routes;
}

/// Package-private mechanical storage for the canonical graph reducer.
class MotionGraphEngineState {
  final RequestLedger ledger = RequestLedger();
  final OperationJournal journal = OperationJournal();
  final RoutePlan routes = RoutePlan();

  MotionGraphReadiness readiness = MotionGraphReadiness.unready;
  MotionGraphPhase phase = MotionGraphPhase.unready;
  bool initialUnitPending = false;
  GraphStateId? requestedState;
  GraphStateId? visualState;
  GraphPresentation? presentation;

  ValidatedMotionGraph? _graph;
  ValidatedGraphIndexes? _indexes;

  /// Accepts either a raw, untrusted definition (validated here) or an
  /// already-[ValidatedMotionGraph]. Dart's runtime type system lets this
  /// simply check `is ValidatedMotionGraph`, unlike the TypeScript original's
  /// `isValidatedGraph` duck-typing helper, which had to distinguish the two
  /// shapes by hand because both are plain objects at runtime there.
  GraphStateId installMetadata(Object? definition) {
    final graph = definition is ValidatedMotionGraph
        ? definition
        : validateMotionGraphDefinition(definition);
    _graph = graph;
    final indexes = getValidatedGraphIndexes(graph);
    _indexes = indexes;
    initialUnitPending =
        indexes.statesById[graph.definition.initialState]?.initialUnit != null;
    return graph.definition.initialState;
  }

  MotionGraphSnapshot snapshot() {
    final currentPresentation = presentation;
    return MotionGraphSnapshot(
      readiness: readiness,
      phase: phase,
      initialUnitPending: initialUnitPending,
      requestedState: requestedState,
      visualState: visualState,
      prospectiveState: routes.prospectiveState(visualState),
      isTransitioning: _isTransitioning(),
      presentation: presentation,
      pendingEdgeId: routes.pending?.edge.id,
      activeEdgeId: routes.active?.edge.id,
      followOnEdgeId: routes.followOn?.edge.id,
      direction: currentPresentation is GraphPresentationReversible
          ? currentPresentation.direction
          : null,
      contentOrdinal: journal.contentOrdinal,
      inputSequence: journal.inputSequence,
      pendingRequestCount: ledger.pendingRequestCount,
      inputsSinceTick: journal.inputsSinceTick,
      routeOperationsLastTick: journal.routeOperationsLastTick,
    );
  }

  MotionGraphEngineCheckpoint checkpoint() {
    return MotionGraphEngineCheckpoint(
      readiness: readiness,
      phase: phase,
      initialUnitPending: initialUnitPending,
      requestedState: requestedState,
      visualState: visualState,
      presentation: presentation,
      ledger: ledger.checkpoint(),
      journal: journal.checkpoint(),
      routes: routes.checkpoint(),
    );
  }

  void restore(MotionGraphEngineCheckpoint checkpoint) {
    readiness = checkpoint.readiness;
    phase = checkpoint.phase;
    initialUnitPending = checkpoint.initialUnitPending;
    requestedState = checkpoint.requestedState;
    visualState = checkpoint.visualState;
    presentation = checkpoint.presentation;
    ledger.restore(checkpoint.ledger);
    journal.restore(checkpoint.journal);
    routes.restore(checkpoint.routes);
  }

  MotionGraphResult record(
    MotionGraphOperation operation,
    List<MotionGraphEffect> effects, {
    OperationResultMetadata metadata = const OperationResultMetadata(),
  }) {
    return journal.record(CompletedOperation(
      operation: operation,
      metadata: metadata,
      presentation: presentation,
      effects: effects,
      snapshot: snapshot(),
    ));
  }

  List<MotionGraphTraceRecord> getTrace() => journal.getTrace();

  GraphPresentationBody bodyPresentation(GraphStateId stateId, int frameIndex) {
    final resolved = state(stateId);
    return GraphPresentationBody(
      state: stateId,
      unitId: resolved.body.unitId,
      frameIndex: frameIndex,
    );
  }

  GraphPresentationStatic staticPresentation(GraphStateId stateId) {
    return GraphPresentationStatic(state: stateId);
  }

  GraphPresentationBody bodyPresentationOrThrow() {
    final current = presentation;
    if (current is! GraphPresentationBody) {
      throw StateError('graph phase requires a body presentation');
    }
    return current;
  }

  SequencedEdge requirePendingRoute() {
    final pending = routes.pending;
    if (pending == null) throw StateError('graph has no pending edge');
    return pending;
  }

  SequencedEdge requireActiveRoute() {
    final active = routes.active;
    if (active == null) throw StateError('graph has no active edge');
    return active;
  }

  GraphEdgeDefinition? edgeDirect(GraphStateId from, GraphStateId to) {
    return indexes().directEdgesByState[from]?[to];
  }

  GraphStateDefinition state(GraphStateId id) {
    final found = indexes().statesById[id];
    if (found == null) {
      throw StateError('validated graph has no state $id');
    }
    return found;
  }

  bool hasState(GraphStateId id) => indexes().statesById.containsKey(id);

  MotionGraphDefinition definition() {
    final graph = _graph;
    if (graph == null) throw StateError('graph metadata is unavailable');
    return graph.definition;
  }

  ValidatedGraphIndexes indexes() {
    final found = _indexes;
    if (found == null) throw StateError('graph indexes are unavailable');
    return found;
  }

  GraphStateId requireVisualState() {
    final found = visualState;
    if (found == null) throw StateError('visual state is unavailable');
    return found;
  }

  GraphStateId requireRequestedState() {
    final found = requestedState;
    if (found == null) throw StateError('requested state is unavailable');
    return found;
  }

  void assertInstalled(String operation) {
    if (_graph == null) {
      throw MotionGraphError(
        MotionGraphErrorCode.notReady,
        '$operation requires graph metadata',
      );
    }
  }

  void assertPhase(MotionGraphPhase expected, String operation) {
    assertInstalled(operation);
    if (phase != expected) {
      throw MotionGraphError(
        MotionGraphErrorCode.notReady,
        '$operation requires phase ${expected.name}, not ${phase.name}',
      );
    }
  }

  bool _isTransitioning() {
    if (phase == MotionGraphPhase.disposed || phase == MotionGraphPhase.error) {
      return false;
    }
    return phase == MotionGraphPhase.waiting ||
        phase == MotionGraphPhase.locked ||
        phase == MotionGraphPhase.reversible ||
        requestedState != visualState;
  }
}
