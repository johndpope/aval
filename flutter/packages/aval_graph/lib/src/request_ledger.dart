/// Request completion-group tracker, ported from
/// `packages/graph/src/request-ledger.ts`.
library;

import 'model.dart';

/// The largest request/sequence ID this package will allocate before
/// throwing, matching JavaScript's `Number.MAX_SAFE_INTEGER`. Dart's native
/// `int` can safely exceed this on the VM, but the bound is kept identical
/// to the TypeScript original so overflow behavior is observably the same.
const int _maxSafeInteger = 9007199254740991;

/// The `settle` variant of [MotionGraphEffect], used as the ledger's result
/// type. Named to mirror the TypeScript `RequestSettleEffect` type alias
/// (`Extract<MotionGraphEffect, { type: "settle" }>`).
typedef RequestSettleEffect = MotionGraphEffectSettle;

class RequestAdmission {
  const RequestAdmission({
    required this.requestId,
    required this.target,
    required this.joined,
    this.superseded,
  });

  final int requestId;
  final GraphStateId target;
  final bool joined;
  final RequestSettleEffect? superseded;
}

class StandaloneSettlement {
  const StandaloneSettlement({required this.requestId, required this.effect});

  final int requestId;
  final RequestSettleEffect effect;
}

class _PendingRequestGroup {
  _PendingRequestGroup({required this.target, required this.requestIds});

  final GraphStateId target;
  final List<int> requestIds;
}

class RequestLedgerPendingCheckpoint {
  const RequestLedgerPendingCheckpoint({
    required this.target,
    required this.requestIds,
  });

  final GraphStateId target;
  final List<int> requestIds;
}

class RequestLedgerCheckpoint {
  const RequestLedgerCheckpoint({required this.nextRequestId, this.pending});

  final int nextRequestId;
  final RequestLedgerPendingCheckpoint? pending;
}

/// Tracks request completion groups without owning promises or scheduling
/// work.
///
/// Duplicate destinations join the current group. A different destination
/// atomically supersedes that group and returns its one `AbortError` effect
/// to the caller. Effects describe microtask timing, but the host remains
/// responsible for applying that timing.
class RequestLedger {
  int _nextRequestId = 1;
  _PendingRequestGroup? _pending;

  int get pendingRequestCount => _pending?.requestIds.length ?? 0;

  GraphStateId? get pendingTarget => _pending?.target;

  /// Adds a request to the surviving completion group for [target].
  RequestAdmission request(GraphStateId target) {
    final requestId = _allocateRequestId();
    final pending = _pending;

    if (pending != null && pending.target == target) {
      pending.requestIds.add(requestId);
      return RequestAdmission(
        requestId: requestId,
        target: target,
        joined: true,
      );
    }

    final superseded = pending == null
        ? null
        : _createSettleEffect(
            pending.requestIds,
            const GraphSettlementReject(GraphSettlementError.abortError),
          );

    _pending = _PendingRequestGroup(target: target, requestIds: [requestId]);

    return RequestAdmission(
      requestId: requestId,
      target: target,
      joined: false,
      superseded: superseded,
    );
  }

  /// Settles and clears the surviving group. Repeated settlement is a no-op.
  RequestSettleEffect? settlePending(GraphSettlement outcome) {
    final pending = _pending;
    if (pending == null) return null;

    _pending = null;
    return _createSettleEffect(pending.requestIds, outcome);
  }

  /// Allocates and settles one request without replacing the surviving
  /// group. This is used for stable no-ops and requests rejected before
  /// admission.
  StandaloneSettlement settleNew(GraphSettlement outcome) {
    final requestId = _allocateRequestId();
    return StandaloneSettlement(
      requestId: requestId,
      effect: _createSettleEffect([requestId], outcome),
    );
  }

  RequestLedgerCheckpoint checkpoint() {
    final pending = _pending;
    return RequestLedgerCheckpoint(
      nextRequestId: _nextRequestId,
      pending: pending == null
          ? null
          : RequestLedgerPendingCheckpoint(
              target: pending.target,
              requestIds: List.unmodifiable(pending.requestIds),
            ),
    );
  }

  void restore(RequestLedgerCheckpoint checkpoint) {
    _nextRequestId = checkpoint.nextRequestId;
    final pending = checkpoint.pending;
    _pending = pending == null
        ? null
        : _PendingRequestGroup(
            target: pending.target,
            requestIds: List.of(pending.requestIds),
          );
  }

  int _allocateRequestId() {
    final requestId = _nextRequestId;
    if (requestId > _maxSafeInteger) {
      throw RangeError('request ID exceeds the safe-integer range');
    }

    _nextRequestId += 1;
    return requestId;
  }
}

RequestSettleEffect _createSettleEffect(
  List<int> requestIds,
  GraphSettlement outcome,
) {
  final sortedRequestIds = List.of(requestIds)..sort();
  return MotionGraphEffectSettle(requestIds: sortedRequestIds, outcome: outcome);
}
