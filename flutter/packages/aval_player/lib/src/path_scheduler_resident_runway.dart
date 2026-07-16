/// The exclusive staged-runway token and its atomic scheduler install.
///
/// Direct port of `packages/player-web/src/runtime/path-scheduler-resident-runway.ts`.
/// The TS staged-token identity check (`staged.token !== transaction`) maps onto
/// `!identical(...)`; `bigint` ordinals become `BigInt`; `media.slice(n)` becomes
/// `sublist(n)`. `Object.freeze`d media/tokens are immutable value objects here.
library;

import 'package:aval_graph/aval_graph.dart';

import 'model.dart';
import 'path_scheduler_cursor_ledger.dart';
import 'path_scheduler_generation.dart';
import 'path_scheduler_model.dart';
import 'path_scheduler_output.dart' show PathSchedulerOutput;
import 'path_scheduler_reservation.dart' show PathSchedulerReservationOwner;
import 'path_scheduler_route.dart' show PathSchedulerRoute;
import 'path_scheduler_validation.dart' show validateResidentRunway;
import 'path_sequence.dart' show PathSequenceState, ResidentPathTarget;

class _StagedResidentRunway {
  const _StagedResidentRunway({
    required this.token,
    required this.generation,
    required this.targetBody,
    required this.firstPresentationOrdinal,
  });

  final PathSchedulerResidentRunwayTransaction token;
  final PathSchedulerGenerationPlan generation;
  final GraphBodyDefinition targetBody;
  final BigInt firstPresentationOrdinal;
}

/// The result of atomically installing a staged runway.
class PathSchedulerResidentRunwayCommit {
  const PathSchedulerResidentRunwayCommit({
    required this.activateWorker,
    required this.build,
    required this.residentTarget,
    required this.retiredGeneration,
    required this.firstPresented,
  });

  final PathSchedulerWorkerActivation activateWorker;
  final PathSequenceState build;
  final ResidentPathTarget residentTarget;
  final int retiredGeneration;
  final RuntimeMediaPresentationFrame? firstPresented;
}

/// Construction options for [PathSchedulerResidentRunwayOwner].
class PathSchedulerResidentRunwayOwnerOptions {
  const PathSchedulerResidentRunwayOwnerOptions({
    required this.rendition,
    required this.generation,
    required this.output,
    required this.route,
    required this.cursors,
    required this.reservation,
  });

  final String rendition;
  final PathSchedulerGeneration generation;
  final PathSchedulerOutput output;
  final PathSchedulerRoute route;
  final PathSchedulerCursorLedger cursors;
  final PathSchedulerReservationOwner reservation;
}

/// Owns the exclusive staged-runway token and its atomic scheduler install.
class PathSchedulerResidentRunwayOwner {
  PathSchedulerResidentRunwayOwner(
    PathSchedulerResidentRunwayOwnerOptions options,
  )   : _rendition = options.rendition,
        _generation = options.generation,
        _output = options.output,
        _route = options.route,
        _cursors = options.cursors,
        _reservation = options.reservation;

  final String _rendition;
  final PathSchedulerGeneration _generation;
  final PathSchedulerOutput _output;
  final PathSchedulerRoute _route;
  final PathSchedulerCursorLedger _cursors;
  final PathSchedulerReservationOwner _reservation;
  _StagedResidentRunway? _current;

  bool get locked => _current != null;

  PathSchedulerResidentRunwayTransaction stage(
    StartResidentRunwayInput input,
  ) {
    if (_current != null) {
      throw RangeError('path scheduler already has a staged resident runway');
    }
    validateResidentRunway(input, _rendition);
    final firstPresentationOrdinal = input.firstPresentationOrdinal ??
        (_cursors.lastDisplayedOrdinal ?? -BigInt.one) + BigInt.one;
    if (firstPresentationOrdinal < BigInt.zero) {
      throw RangeError('resident runway ordinal must be non-negative');
    }
    final generation = _generation.planReplacement(input.path);
    final media = <RuntimeMediaPresentationFrame>[];
    for (var index = 0; index < input.frames.length; index += 1) {
      final resident = input.frames[index];
      media.add(RuntimeMediaPresentationFrame(
        graphKind: RuntimeMediaGraphKind.body,
        state: input.targetState,
        edge: input.edgeId,
        path: input.path,
        frame: RuntimeFrameKey(
          rendition: resident.frame.rendition,
          unit: resident.frame.unit,
          localFrame: resident.frame.localFrame,
        ),
        drawSource: RuntimeMediaDrawSource.resident,
        generation: generation.generation,
        unitInstance: resident.unitInstance,
        decodeOrdinal: resident.decodeOrdinal,
        timestamp: resident.timestamp,
        intendedPresentationOrdinal:
            firstPresentationOrdinal + BigInt.from(index),
      ));
    }
    final token = PathSchedulerResidentRunwayTransaction(
      generation: generation.generation,
      path: input.path,
      edgeId: input.edgeId,
      targetState: input.targetState,
      media: List<RuntimeMediaPresentationFrame>.unmodifiable(media),
    );
    _current = _StagedResidentRunway(
      token: token,
      generation: generation,
      targetBody: input.targetBody,
      firstPresentationOrdinal: firstPresentationOrdinal,
    );
    return token;
  }

  PathSchedulerResidentRunwayCommit commit(
    PathSchedulerResidentRunwayTransaction transaction, [
    CommitResidentRunwayOptions options = const CommitResidentRunwayOptions(),
  ]) {
    final staged = _current;
    if (staged == null || !identical(staged.token, transaction)) {
      throw RangeError('resident runway transaction is stale');
    }
    final alreadyPresented = options.alreadyPresented ?? 0;
    if (alreadyPresented != 0 && alreadyPresented != 1) {
      throw RangeError('resident runway presented count must be zero or one');
    }
    final committed = _generation.commitReplacement(staged.generation);
    _reservation.discard();
    _output.replaceResident(transaction.media.sublist(alreadyPresented));
    _route.activateResident();
    final build = _cursors.replaceSource(
      PathSchedulerSourceReplacementResidentRunway(
        targetState: transaction.targetState,
        targetBody: staged.targetBody,
        runwayFrames: transaction.media.length,
        firstPresentationOrdinal: staged.firstPresentationOrdinal,
      ),
    );
    final residentTarget = ResidentPathTarget(
      edgeId: transaction.edgeId,
      targetState: transaction.targetState,
      targetBody: staged.targetBody,
    );
    final firstPresented = alreadyPresented == 0
        ? null
        : (transaction.media.isEmpty ? null : transaction.media[0]);
    if (alreadyPresented == 1) {
      if (firstPresented == null) {
        throw RangeError('resident runway has no presented frame zero');
      }
      _cursors.recordResidentDisplayed(firstPresented);
    }
    _current = null;
    return PathSchedulerResidentRunwayCommit(
      activateWorker: committed.activateWorker,
      build: build,
      residentTarget: residentTarget,
      retiredGeneration: committed.retiredGeneration,
      firstPresented: firstPresented,
    );
  }

  bool rollback(PathSchedulerResidentRunwayTransaction transaction) {
    if (_current == null || !identical(_current!.token, transaction)) {
      return false;
    }
    _current = null;
    return true;
  }

  void clear() {
    _current = null;
  }
}
