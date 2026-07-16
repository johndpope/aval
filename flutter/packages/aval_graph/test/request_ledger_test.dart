// Ported from packages/graph/test/request-ledger.test.ts
import 'package:aval_graph/aval_graph.dart';
import 'package:aval_graph/src/request_ledger.dart';
import 'package:test/test.dart';

void main() {
  group('RequestLedger', () {
    test('allocates monotonically increasing request IDs', () {
      final ledger = RequestLedger();

      expect(ledger.request('hovered').requestId, 1);
      expect(ledger.request('hovered').requestId, 2);
      expect(
        ledger.settleNew(const GraphSettlementReject(GraphSettlementError.routeError)).requestId,
        3,
      );
      expect(ledger.request('idle').requestId, 4);
    });

    test('joins duplicate requests into the surviving destination group', () {
      final ledger = RequestLedger();

      final first = ledger.request('hovered');
      final second = ledger.request('hovered');

      expect(first.requestId, 1);
      expect(first.target, 'hovered');
      expect(first.joined, false);
      expect(first.superseded, isNull);

      expect(second.requestId, 2);
      expect(second.target, 'hovered');
      expect(second.joined, true);
      expect(second.superseded, isNull);

      expect(ledger.pendingRequestCount, 2);
      expect(ledger.pendingTarget, 'hovered');

      final settled = ledger.settlePending(
        const GraphSettlementResolve(GraphSettlementResolveReason.targetCommitted),
      );
      expect(
        settled,
        MotionGraphEffectSettle(
          requestIds: const [1, 2],
          outcome: const GraphSettlementResolve(GraphSettlementResolveReason.targetCommitted),
        ),
      );
      expect(ledger.pendingRequestCount, 0);
      expect(ledger.pendingTarget, isNull);
    });

    test('supersedes a whole group once and rejects it in request order', () {
      final ledger = RequestLedger();
      ledger.request('success');
      ledger.request('success');

      final replacement = ledger.request('error');

      expect(replacement.requestId, 3);
      expect(replacement.target, 'error');
      expect(replacement.joined, false);
      expect(
        replacement.superseded,
        MotionGraphEffectSettle(
          requestIds: const [1, 2],
          outcome: const GraphSettlementReject(GraphSettlementError.abortError),
        ),
      );
      expect(ledger.pendingRequestCount, 1);
      expect(ledger.pendingTarget, 'error');

      final duplicate = ledger.request('error');
      expect(duplicate.joined, true);
      expect(duplicate.superseded, isNull);
      expect(ledger.pendingRequestCount, 2);

      expect(
        ledger.settlePending(
          const GraphSettlementReject(GraphSettlementError.playbackFallbackError),
        )!
            .requestIds,
        const [3, 4],
      );
      expect(
        ledger.settlePending(const GraphSettlementReject(GraphSettlementError.abortError)),
        isNull,
      );
    });

    test('settles standalone requests without disturbing a pending group', () {
      final ledger = RequestLedger();
      ledger.request('hovered');

      final invalid = ledger.settleNew(const GraphSettlementReject(GraphSettlementError.routeError));

      expect(invalid.requestId, 2);
      expect(
        invalid.effect,
        MotionGraphEffectSettle(
          requestIds: const [2],
          outcome: const GraphSettlementReject(GraphSettlementError.routeError),
        ),
      );
      expect(ledger.pendingRequestCount, 1);
      expect(ledger.pendingTarget, 'hovered');
    });

    test('every returned settlement carries an independent, unmodifiable request-ID list', () {
      final ledger = RequestLedger();
      ledger.request('hovered');
      final superseding = ledger.request('idle');
      final resolved =
          ledger.settlePending(const GraphSettlementResolve(GraphSettlementResolveReason.stableNoop));
      final standalone =
          ledger.settleNew(const GraphSettlementReject(GraphSettlementError.notReadyError));

      expect(superseding.superseded!.requestIds, const [1]);
      expect(resolved!.requestIds, const [2]);
      expect(standalone.effect.requestIds, const [3]);

      expect(
        () => resolved.requestIds.add(99),
        throwsUnsupportedError,
      );
    });

    test('stores the exact settlement outcome value passed in', () {
      final ledger = RequestLedger();
      ledger.request('hovered');
      const outcome = GraphSettlementResolve(GraphSettlementResolveReason.targetCommitted);

      final effect = ledger.settlePending(outcome);

      expect(effect!.outcome, same(outcome));
    });
  });
}
