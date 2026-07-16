// Ported from packages/graph/test/operation-journal.test.ts
import 'package:aval_graph/aval_graph.dart';
import 'package:aval_graph/src/operation_journal.dart';
import 'package:test/test.dart';

void main() {
  group('OperationJournal', () {
    test('admits the bounded input window while every input consumes a sequence', () {
      final journal = OperationJournal();

      for (var index = 1; index <= GraphLimits.maxInputsPerTick; index += 1) {
        final admission = journal.beginInput();
        expect(admission.sequence, index);
        expect(admission.withinLimit, true);
      }

      final overflow1 = journal.beginInput();
      expect(overflow1.sequence, 33);
      expect(overflow1.withinLimit, false);
      final overflow2 = journal.beginInput();
      expect(overflow2.sequence, 34);
      expect(overflow2.withinLimit, false);
      expect(journal.inputsSinceTick, GraphLimits.maxInputsPerTick);
      expect(journal.allocateInternalSequence(), 35);
      expect(journal.inputSequence, 35);
      expect(journal.inputsSinceTick, GraphLimits.maxInputsPerTick);
    });

    test('validates consecutive ordinals without resetting inputs on failed work', () {
      final journal = OperationJournal();
      journal.beginInput();
      journal.beginTick(BigInt.zero);
      journal.incrementRouteOperations();

      expect(
        () => journal.beginTick(BigInt.two),
        throwsA(isA<MotionGraphError>()
            .having((e) => e.code, 'code', MotionGraphErrorCode.nonConsecutiveTick)
            .having((e) => e.message, 'message', 'content ordinal must be 1')),
      );
      expect(journal.contentOrdinal, BigInt.zero);
      expect(journal.inputsSinceTick, 1);
      expect(journal.routeOperationsLastTick, 1);

      journal.beginTick(BigInt.one);
      expect(journal.routeOperationsLastTick, 0);
      expect(journal.inputsSinceTick, 1);
      journal.beginInput();
      expect(journal.inputsSinceTick, 2);

      journal.completeTick();
      expect(journal.inputsSinceTick, 0);
      expect(journal.contentOrdinal, BigInt.one);
    });

    test('enforces the exact per-tick route-operation cap and error', () {
      final journal = OperationJournal();
      journal.beginTick(BigInt.zero);

      for (var count = 0; count < GraphLimits.maxRoutingOperationsPerTick; count += 1) {
        journal.incrementRouteOperations();
      }
      expect(journal.routeOperationsLastTick, GraphLimits.maxRoutingOperationsPerTick);

      expect(
        () => journal.incrementRouteOperations(),
        throwsA(isA<MotionGraphError>()
            .having((e) => e.code, 'code', MotionGraphErrorCode.graphValidation)
            .having(
              (e) => e.message,
              'message',
              'graph exceeded the per-tick routing-operation bound',
            )),
      );
      expect(journal.routeOperationsLastTick, GraphLimits.maxRoutingOperationsPerTick + 1);

      journal.beginTick(BigInt.one);
      expect(journal.routeOperationsLastTick, 0);
    });

    test('records the completed presentation and snapshot in a frozen result', () {
      final journal = OperationJournal();
      const presentation = GraphPresentationBody(state: 'idle', unitId: 'idle-loop', frameIndex: 3);
      final snapshot = _frozenSnapshot(presentation);
      const effect = MotionGraphEffectRequestedStateChange(from: 'idle', to: 'hovered', sequence: 1);

      final result = journal.record(CompletedOperation(
        operation: MotionGraphOperation.request,
        presentation: presentation,
        effects: const [effect],
        snapshot: snapshot,
        metadata: const OperationResultMetadata(
          accepted: true,
          joined: false,
          sequence: 1,
          requestId: 1,
        ),
      ));

      expect(result.operation, MotionGraphOperation.request);
      expect(result.accepted, true);
      expect(result.joined, false);
      expect(result.sequence, 1);
      expect(result.requestId, 1);
      expect(result.presentation, same(presentation));
      expect(result.effects, const [effect]);
      expect(result.snapshot, same(snapshot));
      expect(journal.getTrace(), [MotionGraphTraceRecord(index: 1, result: result)]);
    });

    test('retains only the newest trace window with absolute indices', () {
      final journal = OperationJournal();
      final snapshot = _frozenSnapshot(null);
      final total = GraphLimits.maxTraceRecords + 4;

      for (var index = 0; index < total; index += 1) {
        journal.record(CompletedOperation(
          operation: MotionGraphOperation.tick,
          effects: const [],
          presentation: null,
          snapshot: snapshot,
        ));
      }

      final trace = journal.getTrace();
      expect(trace, hasLength(GraphLimits.maxTraceRecords));
      expect(trace.first.index, 5);
      expect(trace.last.index, total);
      expect(() => trace.add(trace.first), throwsUnsupportedError);
    });
  });
}

MotionGraphSnapshot _frozenSnapshot(GraphPresentation? presentation) {
  return MotionGraphSnapshot(
    readiness: MotionGraphReadiness.animated,
    phase: MotionGraphPhase.stable,
    initialUnitPending: false,
    requestedState: 'idle',
    visualState: 'idle',
    prospectiveState: 'idle',
    isTransitioning: false,
    presentation: presentation,
    pendingEdgeId: null,
    activeEdgeId: null,
    followOnEdgeId: null,
    direction: null,
    contentOrdinal: null,
    inputSequence: 0,
    pendingRequestCount: 0,
    inputsSinceTick: 0,
    routeOperationsLastTick: 0,
  );
}
