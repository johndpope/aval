/// Port of `packages/player-web/src/runtime/path-scheduler.test.ts` (1:1).
///
/// The TS suite drives the real `WorkerSampleFactory` + asset catalog + the
/// `.avl` container fixtures (`asset-test-fixture.ts`). Those modules depend on
/// `aval_format`'s container/AVC surface, which is a later phase and not yet
/// ported. Because the frozen `worker_samples.dart` deliberately exposes
/// `WorkerSampleFactory` as an *interface*, this port substitutes a faithful
/// test-local factory (`_FakeWorkerSampleFactory`) that reproduces exactly the
/// load-bearing behavior the scheduler observes: it drives the same
/// `DecodeTimeline.planSampleBatch(...).commit()` the real factory does
/// (worker-samples.ts:145,203) to assign ordinal/unitInstance/timestamp/
/// duration, and classifies frame 0 as `key` else `delta` (matching the fixture
/// access units in asset-test-fixture.ts). Sample bytes are irrelevant to every
/// scheduler assertion, so a placeholder buffer is used. The unit frame-count
/// tables mirror `createOpaqueTestAsset` / `createIntegratedPathTestAsset`.
///
/// `FakeWorker` / `FakeManagedFrame` are ported verbatim from the TS fixture
/// (Promise → Future, resolve-callbacks → Completers).
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:aval_graph/aval_graph.dart';
import 'package:aval_player/aval_player.dart';
import 'package:test/test.dart';

const DecoderWorkerLimits limits = DecoderWorkerLimits(
  maxDecodeQueueSize: 8,
  maxPendingSamples: 12,
  maxOutstandingFrames: 12,
  maxDecodedBytes: 12 * 64 * 64 * 4,
);

void main() {
  group('PathScheduler continuous source pumping', () {
    test('keeps complete loop occurrences continuous under bounded credit',
        () async {
      final fixture = createFixture();
      await fixture.scheduler.startBody(StartScheduledBodyInput(
        state: 'idle',
        body: body('body', GraphBodyKind.loop, 2, [1]),
        outgoingStarts: [portalStart()],
        path: 'idle-loop',
      ));

      final presented = <List<int>>[];
      for (var index = 0; index < 10; index += 1) {
        final report =
            await fixture.scheduler.pump(const PathSchedulerPumpOptions(
          targetRingFrames: 6,
        ));
        expect(report.ringSize, lessThanOrEqualTo(6));
        final result = fixture.scheduler.takeNext();
        final frame = requireStreaming(result);
        presented.add([
          frame.media.unitInstance,
          frame.media.frame.localFrame,
          frame.media.decodeOrdinal,
        ]);
        frame.frame.closeFrame();
      }

      expect(
        presented.map((value) => value.sublist(0, 2)).toList(),
        [
          [0, 0], [0, 1], [1, 0], [1, 1], [2, 0], //
          [2, 1], [3, 0], [3, 1], [4, 0], [4, 1],
        ],
      );
      expect(
        presented.map((value) => value[2]).toList(),
        List<int>.generate(10, (index) => index),
      );
      expect(fixture.worker.maximumSubmittedBatch, lessThanOrEqualTo(6));
      final snapshot = fixture.scheduler.snapshot();
      expect(snapshot.generation, 1);
      expect(snapshot.activePath, 'idle-loop');
      expect(snapshot.smoothSession, true);
      expect(snapshot.status, PathSchedulerStatus.active);
      await fixture.scheduler.dispose();
      expect(fixture.worker.openFrames, 0);
    });

    test('never submits past the unresolved portal horizon', () async {
      final fixture = createFixture();
      await fixture.scheduler.startBody(StartScheduledBodyInput(
        state: 'idle',
        body: body('body', GraphBodyKind.loop, 2, [0, 1]),
        outgoingStarts: [portalStart()],
        path: 'bounded-source',
      ));

      await fixture.scheduler
          .pump(const PathSchedulerPumpOptions(targetRingFrames: 6));
      final snapshot = fixture.scheduler.snapshot();
      expect(
        snapshot.submittedSource,
        SourceBodyCursor(occurrence: BigInt.two, frame: 1),
      );
      expect(
        snapshot.unresolvedMaximumSubmitted,
        SourceBodyCursor(occurrence: BigInt.from(3), frame: 0),
      );
      expect(snapshot.ringSize, 6);
    });

    test('maintains the same order under controllable worker output latency',
        () async {
      final slow = createFixture(FakeWorkerOptions(outputsPerWait: 1));
      final fast = createFixture(FakeWorkerOptions(outputsPerWait: 4));
      for (final fixture in [slow, fast]) {
        await fixture.scheduler.startBody(StartScheduledBodyInput(
          state: 'idle',
          body: body('body', GraphBodyKind.loop, 2, [1]),
          outgoingStarts: [portalStart()],
          path: 'latency',
        ));
      }

      final slowReport = await slow.scheduler
          .pump(const PathSchedulerPumpOptions(targetRingFrames: 4));
      final fastReport = await fast.scheduler
          .pump(const PathSchedulerPumpOptions(targetRingFrames: 4));
      expect(slowReport.waits, 4);
      expect(fastReport.waits, 1);
      expect(
        [slow, fast].map((fixture) => fixture.scheduler.snapshot().ringSize),
        [4, 4],
      );
    });
  });

  group('PathScheduler locked and target paths', () {
    test('prepares a complete locked bridge plus target zero before route commit',
        () async {
      final fixture = createFixture();
      await startAtSourceZero(fixture);

      final decision = await fixture.scheduler.prepareRoute(
        PrepareScheduledRouteInput(
          edge: lockedEdge('to-target', 2),
          targetState: 'target',
          targetBody: body('body', GraphBodyKind.loop, 2, [1]),
        ),
      );
      expect(decision, isA<SubmissionHorizonSelectPortal>());
      expect((decision as SubmissionHorizonSelectPortal).boundary.frame, 1);

      await fixture.scheduler
          .pump(const PathSchedulerPumpOptions(targetRingFrames: 6));
      final sourceBoundary = requireStreaming(fixture.scheduler.takeNext());
      expect(sourceBoundary.purpose, PathSchedulerFramePurpose.source);
      expect(sourceBoundary.media.frame.localFrame, 1);
      sourceBoundary.frame.closeFrame();

      final routeDecision = fixture.scheduler.routeDecision();
      expect(routeDecision, isA<SubmissionHorizonCommitEdge>());
      final commitEdge = routeDecision! as SubmissionHorizonCommitEdge;
      expect(commitEdge.lead?.requiredConsecutiveFrames, 3);
      expect(commitEdge.lead?.ready, true);
      fixture.scheduler.commitPreparedRoute();

      final bridgeZero = requireStreaming(fixture.scheduler.takeNext());
      final bridgeOne = requireStreaming(fixture.scheduler.takeNext());
      final targetZero = requireStreaming(fixture.scheduler.takeNext());
      expect(
        [identity(bridgeZero), identity(bridgeOne), identity(targetZero)],
        [
          ['bridge', 'intro', 0],
          ['bridge', 'intro', 1],
          ['target', 'body', 0],
        ],
      );
      bridgeZero.frame.closeFrame();
      bridgeOne.frame.closeFrame();
      targetZero.frame.closeFrame();
    });

    test('continues the target loop with complete new occurrences', () async {
      final fixture = createFixture();
      await startAtSourceZero(fixture);
      await fixture.scheduler.prepareRoute(PrepareScheduledRouteInput(
        edge: lockedEdge('to-target', 2),
        targetState: 'target',
        targetBody: body('body', GraphBodyKind.loop, 2, [1]),
      ));
      await fixture.scheduler
          .pump(const PathSchedulerPumpOptions(targetRingFrames: 6));
      closeStreaming(fixture.scheduler.takeNext());
      fixture.scheduler.commitPreparedRoute();

      final values = <List<Object>>[];
      for (var index = 0; index < 6; index += 1) {
        final current = requireStreaming(fixture.scheduler.takeNext());
        values.add([
          current.purpose.wireValue,
          current.media.unitInstance,
          current.media.frame.localFrame,
        ]);
        current.frame.closeFrame();
        await fixture.scheduler
            .pump(const PathSchedulerPumpOptions(targetRingFrames: 6));
      }
      expect(values, [
        ['bridge', 1, 0],
        ['bridge', 1, 1],
        ['target', 2, 0],
        ['target', 2, 1],
        ['target', 3, 0],
        ['target', 3, 1],
      ]);
    });
  });

  group('PathScheduler generation replacement and recovery', () {
    test(
        'restarts pending replacement from frame zero while retaining global decode time',
        () async {
      final fixture = createFixture(FakeWorkerOptions(retainOneStaleOutput: true));
      await startAtSourceZero(fixture);
      await fixture.scheduler.prepareRoute(PrepareScheduledRouteInput(
        edge: lockedEdge('first-route', 2),
        targetState: 'first',
        targetBody: body('body', GraphBodyKind.loop, 2, [1]),
      ));
      await fixture.scheduler
          .pump(const PathSchedulerPumpOptions(targetRingFrames: 4));
      final before = fixture.scheduler.snapshot();

      final replacement =
          await fixture.scheduler.prepareRoute(PrepareScheduledRouteInput(
        edge: lockedEdge('replacement-route', 2),
        targetState: 'replacement',
        targetBody: body('body', GraphBodyKind.loop, 2, [1]),
      ));
      expect(replacement, isA<SubmissionHorizonSelectPortal>());
      final afterReplace = fixture.scheduler.snapshot();
      expect(afterReplace.generation, 2);
      expect(afterReplace.pendingEdge, 'replacement-route');
      expect(afterReplace.ringSize, 0);

      await fixture.scheduler
          .pump(const PathSchedulerPumpOptions(targetRingFrames: 4));
      final resumed = requireStreaming(fixture.scheduler.takeNext());
      expect(resumed.purpose, PathSchedulerFramePurpose.source);
      expect(resumed.media.frame.localFrame, 1);
      expect(
        resumed.media.decodeOrdinal,
        greaterThan(before.nextDecodeOrdinal - 1),
      );
      resumed.frame.closeFrame();
      expect(
        fixture.scheduler.trace().any(
              (record) =>
                  record.operation == PathSchedulerTraceOperation.staleOutput,
            ),
        true,
      );
    });

    test('hands a resident runway to the exact streamed continuation', () async {
      final fixture = createFixture();
      await startAtSourceZero(fixture);
      final runway = List<PathSchedulerResidentFrame>.generate(
        6,
        (index) => resident(index % 2),
      );

      await fixture.scheduler.startResidentRunway(StartResidentRunwayInput(
        edgeId: 'cut-to-target',
        targetState: 'target',
        targetBody: body('body', GraphBodyKind.loop, 2, [1]),
        frames: runway,
        path: 'cut-target',
      ));
      await fixture.scheduler
          .pump(const PathSchedulerPumpOptions(targetRingFrames: 2));

      final ordinals = <BigInt>[];
      for (var index = 0; index < runway.length; index += 1) {
        final current = fixture.scheduler.takeNext();
        expect(current.kind, 'resident');
        final residentResult = current as PathSchedulerTakeResident;
        expect(residentResult.media.frame.localFrame, index % 2);
        ordinals.add(residentResult.media.intendedPresentationOrdinal);
      }
      final streamed = requireStreaming(fixture.scheduler.takeNext());
      expect(streamed.purpose, PathSchedulerFramePurpose.target);
      expect(streamed.media.frame.localFrame, 0);
      expect(
        streamed.media.intendedPresentationOrdinal,
        ordinals.last + BigInt.one,
      );
      streamed.frame.closeFrame();
      expect(fixture.scheduler.snapshot().discardedDependencyFrames, 6);
    });

    test('rolls back a staged runway without disturbing a source reservation',
        () async {
      final fixture = createFixture();
      await startAtSourceZero(fixture);
      await fixture.scheduler
          .pump(const PathSchedulerPumpOptions(targetRingFrames: 1));
      final source = requireStreaming(fixture.scheduler.reserveNext());
      final before = fixture.scheduler.snapshot();
      final transaction =
          fixture.scheduler.stageResidentRunway(StartResidentRunwayInput(
        edgeId: 'cut-to-target',
        targetState: 'target',
        targetBody: body('body', GraphBodyKind.loop, 2, [1]),
        frames: List<PathSchedulerResidentFrame>.generate(
          6,
          (index) => resident(index % 2),
        ),
        path: 'cut:staged',
      ));

      expect(fixture.scheduler.snapshot(), before);
      expect(fixture.scheduler.rollbackResidentRunway(transaction), true);
      fixture.scheduler.commitPreparedPresentation(source.media);
      source.frame.closeFrame();
      final snapshot = fixture.scheduler.snapshot();
      expect(snapshot.generation, 1);
      expect(snapshot.activePath, 'source');
      expect(
        snapshot.displayedSource,
        SourceBodyCursor(occurrence: BigInt.zero, frame: 1),
      );
    });

    test('commits the exact staged generation and records drawn frame zero directly',
        () async {
      final fixture = createFixture();
      await startAtSourceZero(fixture);
      final gate = fixture.worker.gateNextActivation();
      final transaction =
          fixture.scheduler.stageResidentRunway(StartResidentRunwayInput(
        edgeId: 'cut-to-target',
        targetState: 'target',
        targetBody: body('body', GraphBodyKind.loop, 2, [1]),
        frames: List<PathSchedulerResidentFrame>.generate(
          6,
          (index) => resident(index % 2),
        ),
        path: 'cut:transaction',
        firstPresentationOrdinal: BigInt.from(9),
      ));

      expect(transaction.generation, 2);
      expect(
        transaction.media.map((frame) => frame.generation).toList(),
        List<int>.generate(6, (_) => 2),
      );
      expect(
        transaction.media
            .map((frame) => frame.intendedPresentationOrdinal)
            .toList(),
        [
          BigInt.from(9),
          BigInt.from(10),
          BigInt.from(11),
          BigInt.from(12),
          BigInt.from(13),
          BigInt.from(14),
        ],
      );
      final staged = fixture.scheduler.snapshot();
      expect(staged.generation, 1);
      expect(staged.activePath, 'source');
      expect(staged.residentFrames, 0);

      final activateWorker = fixture.scheduler.commitResidentRunway(
        transaction,
        const CommitResidentRunwayOptions(alreadyPresented: 1),
      );
      final afterCommit = fixture.scheduler.snapshot();
      expect(afterCommit.generation, 2);
      expect(afterCommit.activePath, 'cut:transaction');
      expect(afterCommit.residentFrames, 5);
      expect(afterCommit.displayedCursor?.path, 'cut:transaction');
      expect(afterCommit.displayedCursor?.unit, 'body');
      expect(afterCommit.displayedCursor?.localFrame, 0);
      expect(fixture.worker.activeGeneration, 1);
      final next = fixture.scheduler.reserveNext();
      expect(next.kind, 'resident');
      final residentNext = next as PathSchedulerTakeResident;
      expect(identical(residentNext.media, transaction.media[1]), true);
      fixture.scheduler.commitPreparedPresentation(residentNext.media);

      final activation = activateWorker();
      await gate.entered;
      gate.release();
      await activation;
      expect(
        fixture.scheduler
            .trace()
            .where((record) =>
                record.operation ==
                PathSchedulerTraceOperation.residentPresent)
            .length,
        2,
      );
    });

    test('locks non-token replacement until a staged runway rolls back',
        () async {
      final fixture = createFixture();
      await startAtSourceZero(fixture);
      await fixture.scheduler.prepareRoute(PrepareScheduledRouteInput(
        edge: lockedEdge('obsolete', 2),
        targetState: 'obsolete',
        targetBody: body('body', GraphBodyKind.loop, 2, [1]),
      ));
      final transaction =
          fixture.scheduler.stageResidentRunway(StartResidentRunwayInput(
        edgeId: 'cut-to-target',
        targetState: 'target',
        targetBody: body('body', GraphBodyKind.loop, 2, [1]),
        frames: List<PathSchedulerResidentFrame>.generate(
          6,
          (index) => resident(index % 2),
        ),
        path: 'cut:locked',
      ));

      await expectLater(
        fixture.scheduler.prepareRoute(PrepareScheduledRouteInput(
          edge: lockedEdge('replacement', 2),
          targetState: 'replacement',
          targetBody: body('body', GraphBodyKind.loop, 2, [1]),
        )),
        throwsA(isA<RangeError>().having(
          (error) => error.toString(),
          'message',
          contains('locked by a staged resident runway'),
        )),
      );
      final locked = fixture.scheduler.snapshot();
      expect(locked.generation, 1);
      expect(locked.pendingEdge, 'obsolete');

      expect(fixture.scheduler.rollbackResidentRunway(transaction), true);
      final resolved =
          await fixture.scheduler.prepareRoute(PrepareScheduledRouteInput(
        edge: lockedEdge('replacement', 2),
        targetState: 'replacement',
        targetBody: body('body', GraphBodyKind.loop, 2, [1]),
      ));
      expect(resolved, isA<SubmissionHorizonSelectPortal>());
      expect(fixture.scheduler.snapshot().generation, 2);
    });

    test('reserves after a synchronously advanced in-flight replacement',
        () async {
      final fixture = createFixture();
      await startAtSourceZero(fixture);
      await fixture.scheduler.prepareRoute(PrepareScheduledRouteInput(
        edge: lockedEdge('obsolete', 2),
        targetState: 'obsolete',
        targetBody: body('body', GraphBodyKind.loop, 2, [1]),
      ));
      final gate = fixture.worker.gateNextActivation();
      final replacement =
          fixture.scheduler.prepareRoute(PrepareScheduledRouteInput(
        edge: lockedEdge('replacement', 2),
        targetState: 'replacement',
        targetBody: body('body', GraphBodyKind.loop, 2, [1]),
      ));
      await gate.entered;
      expect(fixture.scheduler.snapshot().generation, 2);

      final transaction =
          fixture.scheduler.stageResidentRunway(StartResidentRunwayInput(
        edgeId: 'cut-to-target',
        targetState: 'target',
        targetBody: body('body', GraphBodyKind.loop, 2, [1]),
        frames: List<PathSchedulerResidentFrame>.generate(
          6,
          (index) => resident(index % 2),
        ),
        path: 'cut:after-in-flight',
      ));
      expect(transaction.generation, 3);
      gate.release();
      await replacement;
      await fixture.scheduler.commitResidentRunway(transaction)();
      final snapshot = fixture.scheduler.snapshot();
      expect(snapshot.generation, 3);
      expect(snapshot.activePath, 'cut:after-in-flight');
    });

    test('keeps a preserved source coherent when replacement acknowledgement aborts',
        () async {
      final fixture = createFixture();
      await startAtSourceZero(fixture);
      await fixture.scheduler.prepareRoute(PrepareScheduledRouteInput(
        edge: lockedEdge('obsolete', 2),
        targetState: 'obsolete',
        targetBody: body('body', GraphBodyKind.loop, 2, [1]),
      ));
      await fixture.scheduler
          .pump(const PathSchedulerPumpOptions(targetRingFrames: 6));
      final reserved = requireStreaming(fixture.scheduler.reserveNext());
      expect(reserved.media.frame.localFrame, 1);
      final gate = fixture.worker.gateNextActivation();
      final controller = AbortController();
      final cancellation = fixture.scheduler.cancelPreparedRoute(
        'cancel:obsolete',
        controller.signal,
        true,
      );
      await gate.entered;

      final duringAbort = fixture.scheduler.snapshot();
      expect(duringAbort.generation, 2);
      expect(duringAbort.activePath, 'cancel:obsolete');
      expect(duringAbort.pendingEdge, null);
      expect(
        duringAbort.displayedSource,
        SourceBodyCursor(occurrence: BigInt.zero, frame: 0),
      );
      controller.abort(DOMException('replacement superseded', 'AbortError'));
      await expectLater(
        cancellation,
        throwsA(isA<DOMException>()
            .having((error) => error.name, 'name', 'AbortError')),
      );
      gate.release();
      await Future<void>.value();

      fixture.scheduler.commitPreparedPresentation(reserved.media);
      reserved.frame.closeFrame();
      await fixture.scheduler
          .pump(const PathSchedulerPumpOptions(targetRingFrames: 1));
      final adjacent = requireStreaming(fixture.scheduler.takeNext());
      expect(adjacent.media.frame.localFrame, 0);
      expect(
        adjacent.media.intendedPresentationOrdinal,
        reserved.media.intendedPresentationOrdinal + BigInt.one,
      );
      adjacent.frame.closeFrame();
    });

    test('does not let a stale token rollback a newer staged runway', () async {
      final fixture = createFixture();
      await startAtSourceZero(fixture);
      StartResidentRunwayInput input(String path) => StartResidentRunwayInput(
            edgeId: 'cut-to-target',
            targetState: 'target',
            targetBody: body('body', GraphBodyKind.loop, 2, [1]),
            frames: List<PathSchedulerResidentFrame>.generate(
              6,
              (index) => resident(index % 2),
            ),
            path: path,
          );
      final stale = fixture.scheduler.stageResidentRunway(input('cut:first'));
      expect(fixture.scheduler.rollbackResidentRunway(stale), true);
      final current =
          fixture.scheduler.stageResidentRunway(input('cut:current'));

      expect(fixture.scheduler.rollbackResidentRunway(stale), false);
      await fixture.scheduler.commitResidentRunway(current)();
      final snapshot = fixture.scheduler.snapshot();
      expect(snapshot.generation, 2);
      expect(snapshot.activePath, 'cut:current');
      expect(snapshot.residentFrames, 6);
      expect(fixture.scheduler.rollbackResidentRunway(current), false);
    });

    test('hands a long finite runway to its terminal frame and then holds',
        () async {
      final fixture = createFixture(FakeWorkerOptions(integratedPathAsset: true));
      await fixture.scheduler.startBody(StartScheduledBodyInput(
        state: 'source',
        body: body('idle-body', GraphBodyKind.loop, 4, [3]),
        outgoingStarts: [portalStart()],
        path: 'source',
      ));
      await fixture.scheduler
          .pump(const PathSchedulerPumpOptions(targetRingFrames: 1));
      closeStreaming(fixture.scheduler.takeNext());
      final finite = body('idle-body', GraphBodyKind.finite, 4, [3]);
      final runway = [0, 1, 2, 3, 3, 3]
          .map((frame) => residentFor('opaque-path', 'idle-body', frame))
          .toList();

      await fixture.scheduler.startResidentRunway(StartResidentRunwayInput(
        edgeId: 'cut-to-finite',
        targetState: 'finite',
        targetBody: finite,
        frames: runway,
        path: 'cut-finite',
      ));
      await fixture.scheduler
          .pump(const PathSchedulerPumpOptions(targetRingFrames: 2));
      for (final expected in [0, 1, 2, 3, 3, 3]) {
        final current = fixture.scheduler.takeNext();
        expect(current.kind, 'resident');
        expect((current as PathSchedulerTakeResident).media.frame.localFrame,
            expected);
      }
      final handoff = requireStreaming(fixture.scheduler.takeNext());
      expect(handoff.media.frame.localFrame, 3);
      handoff.frame.closeFrame();
      fixture.scheduler.promoteTargetToSource(
        state: 'finite',
        body: finite,
        outgoingStarts: const <GraphStartPolicy>[],
      );

      await fixture.scheduler
          .pump(const PathSchedulerPumpOptions(targetRingFrames: 2));
      expect(fixture.scheduler.takeNext().kind, 'held');
      final snapshot = fixture.scheduler.snapshot();
      expect(snapshot.discardedDependencyFrames, 3);
      expect(
        snapshot.displayedSource,
        SourceBodyCursor(occurrence: BigInt.zero, frame: 3),
      );
    });

    test('discards a reserved route without advancing and replaces it in-place',
        () async {
      final fixture = createFixture();
      await startAtSourceZero(fixture);
      await fixture.scheduler.prepareRoute(PrepareScheduledRouteInput(
        edge: lockedEdge('obsolete', 2),
        targetState: 'obsolete',
        targetBody: body('body', GraphBodyKind.loop, 2, [1]),
      ));
      await fixture.scheduler
          .pump(const PathSchedulerPumpOptions(targetRingFrames: 6));
      closeStreaming(fixture.scheduler.takeNext());
      final before = fixture.scheduler.snapshot().displayedSource;
      final obsolete = fixture.scheduler.reserveNext(true);
      expect(obsolete.kind, 'frame');
      (obsolete as PathSchedulerTakeFrame).frame.closeFrame();
      expect(fixture.scheduler.snapshot().displayedSource, before);
      fixture.scheduler.discardPreparedPresentation();

      await fixture.scheduler.prepareRoute(PrepareScheduledRouteInput(
        edge: lockedEdge('latest', 2),
        targetState: 'latest',
        targetBody: body('body', GraphBodyKind.loop, 2, [1]),
        replacementPath: 'route:latest',
      ));
      final snapshot = fixture.scheduler.snapshot();
      expect(snapshot.generation, 2);
      expect(snapshot.activePath, 'route:latest');
      expect(snapshot.pendingEdge, 'latest');
      expect(snapshot.displayedSource, before);
      expect(
        fixture.scheduler.trace().any((record) =>
            record.operation == PathSchedulerTraceOperation.routeCommit &&
            record.reason == 'obsolete'),
        false,
      );
    });

    test('cancels an uncommitted route at a terminal finite source', () async {
      final fixture = createFixture();
      final finite = body('body', GraphBodyKind.finite, 2, [1]);
      await fixture.scheduler.startBody(StartScheduledBodyInput(
        state: 'finite',
        body: finite,
        outgoingStarts: [portalStart()],
        path: 'finite',
      ));
      await fixture.scheduler
          .pump(const PathSchedulerPumpOptions(targetRingFrames: 2));
      closeStreaming(fixture.scheduler.takeNext());
      closeStreaming(fixture.scheduler.takeNext());
      await fixture.scheduler.prepareRoute(PrepareScheduledRouteInput(
        edge: lockedEdgeFrom('obsolete', 'finite', 'target', 2),
        targetState: 'target',
        targetBody: body('body', GraphBodyKind.loop, 2, [1]),
      ));
      await fixture.scheduler.cancelPreparedRoute('cancel:finite');

      final snapshot = fixture.scheduler.snapshot();
      expect(snapshot.generation, 2);
      expect(snapshot.activePath, 'cancel:finite');
      expect(snapshot.pendingEdge, null);
      expect(
        snapshot.displayedSource,
        SourceBodyCursor(occurrence: BigInt.zero, frame: 1),
      );
      await fixture.scheduler
          .pump(const PathSchedulerPumpOptions(targetRingFrames: 2));
      expect(fixture.scheduler.takeNext().kind, 'held');
    });

    test('turns a worker watchdog into a failed, cleaned scheduler', () async {
      final fixture = createFixture(FakeWorkerOptions(watchdog: true));
      await fixture.scheduler.startBody(StartScheduledBodyInput(
        state: 'idle',
        body: body('body', GraphBodyKind.loop, 2, [1]),
        outgoingStarts: [portalStart()],
        path: 'watchdog',
      ));

      await expectLater(
        fixture.scheduler.pump(const PathSchedulerPumpOptions(
          targetRingFrames: 2,
          timeoutMs: 5,
        )),
        throwsA(isA<DecoderWorkerWatchdogError>()),
      );
      final snapshot = fixture.scheduler.snapshot();
      expect(snapshot.status, PathSchedulerStatus.error);
      expect(snapshot.smoothSession, false);
      expect(snapshot.ringSize, 0);
      expect(fixture.worker.openFrames, 0);
    });
  });

  group('PathScheduler ownership and diagnostics', () {
    test('reports underflow without fabricating a presentation and bounds traces',
        () async {
      final fixture = createFixture();
      await fixture.scheduler.startBody(StartScheduledBodyInput(
        state: 'idle',
        body: body('body', GraphBodyKind.loop, 2, [1]),
        outgoingStarts: [portalStart()],
        path: 'underflow',
      ));

      for (var index = 0; index < 520; index += 1) {
        expect(fixture.scheduler.takeNext().kind, 'underflow');
      }
      final trace = fixture.scheduler.trace();
      expect(trace.length, 512);
      expect(trace[0].index, greaterThan(0));
      expect(trace.last.operation, PathSchedulerTraceOperation.underflow);
      expect(fixture.scheduler.snapshot().smoothSession, false);
    });

    test('disposes queued, ring-owned, and worker-owned frames exactly once',
        () async {
      final fixture = createFixture();
      await fixture.scheduler.startBody(StartScheduledBodyInput(
        state: 'idle',
        body: body('body', GraphBodyKind.loop, 2, [1]),
        outgoingStarts: [portalStart()],
        path: 'cleanup',
      ));
      await fixture.scheduler
          .pump(const PathSchedulerPumpOptions(targetRingFrames: 6));
      expect(fixture.worker.openFrames, 6);

      await fixture.scheduler.dispose();
      await fixture.scheduler.dispose();
      expect(fixture.worker.openFrames, 0);
      expect(fixture.worker.abortCalls, 1);
      final snapshot = fixture.scheduler.snapshot();
      expect(snapshot.status, PathSchedulerStatus.disposed);
      expect(snapshot.ringSize, 0);
      expect(snapshot.expectedOutputs, 0);
      expect(snapshot.residentFrames, 0);
    });
  });
}

// --------------------------------------------------------------------------
// Fixture scaffolding (ported from path-scheduler.test.ts:666-1013).
// --------------------------------------------------------------------------

class Fixture {
  Fixture(this.worker, this.scheduler);

  final FakeWorker worker;
  final PathScheduler scheduler;
}

const Map<String, int> _opaqueUnitFrames = {'body': 2, 'intro': 2};

const Map<String, int> _integratedPathUnitFrames = {
  'idle-body': 4,
  'hover-body': 3,
  'loading-body': 3,
  'archive-body': 3,
  'success-body': 2,
  'done-body': 1,
  'intro': 2,
  'one-bridge': 1,
  'long-bridge': 5,
};

Fixture createFixture([FakeWorkerOptions options = const FakeWorkerOptions()]) {
  final integrated = options.integratedPathAsset;
  final timeline = DecodeTimeline(
    const RationalFrameRate(numerator: 30, denominator: 1),
  );
  final worker = FakeWorker(options);
  final samples = _FakeWorkerSampleFactory(
    timeline: timeline,
    units: integrated ? _integratedPathUnitFrames : _opaqueUnitFrames,
  );
  final scheduler = PathScheduler(PathSchedulerOptions(
    timeline: timeline,
    samples: samples,
    worker: worker,
    rendition: integrated ? 'opaque-path' : 'opaque',
    ringCapacity: 6,
    limits: limits,
    clock: _CountingClock(),
  ));
  return Fixture(worker, scheduler);
}

Future<void> startAtSourceZero(Fixture fixture) async {
  await fixture.scheduler.startBody(StartScheduledBodyInput(
    state: 'idle',
    body: body('body', GraphBodyKind.loop, 2, [1]),
    outgoingStarts: [portalStart()],
    path: 'source',
  ));
  await fixture.scheduler
      .pump(const PathSchedulerPumpOptions(targetRingFrames: 1));
  closeStreaming(fixture.scheduler.takeNext());
}

GraphBodyDefinition body(
  String unitId,
  GraphBodyKind kind,
  int frameCount,
  List<int> portals,
) {
  return GraphBodyDefinition(
    unitId: unitId,
    kind: kind,
    frameCount: frameCount,
    ports: [GraphPortDefinition(id: 'default', portalFrames: portals)],
  );
}

GraphStartPolicyPortal portalStart() {
  return const GraphStartPolicyPortal(
    sourcePort: 'default',
    targetPort: 'default',
    maxWaitFrames: 6,
  );
}

GraphEdgeDefinition lockedEdge(String id, int frameCount) {
  return lockedEdgeFrom(id, 'idle', 'target', frameCount);
}

GraphEdgeDefinition lockedEdgeFrom(
  String id,
  String from,
  String to,
  int frameCount,
) {
  return GraphEdgeDefinition(
    id: id,
    from: from,
    to: to,
    start: portalStart(),
    transition: GraphTransitionLocked(unitId: 'intro', frameCount: frameCount),
    continuity: GraphContinuity.exactAuthored,
  );
}

PathSchedulerResidentFrame resident(int localFrame) {
  return residentFor('opaque', 'body', localFrame);
}

PathSchedulerResidentFrame residentFor(
  String rendition,
  String unit,
  int localFrame,
) {
  return PathSchedulerResidentFrame(
    frame: RuntimeFrameKey(
      rendition: rendition,
      unit: unit,
      localFrame: localFrame,
    ),
    unitInstance: 0,
    decodeOrdinal: localFrame,
    timestamp: localFrame * 33333,
  );
}

PathSchedulerTakeFrame requireStreaming(PathSchedulerTakeResult result) {
  if (result is! PathSchedulerTakeFrame) {
    throw StateError('expected streaming frame, received ${result.kind}');
  }
  return result;
}

void closeStreaming(PathSchedulerTakeResult result) {
  requireStreaming(result).frame.closeFrame();
}

List<Object> identity(PathSchedulerTakeFrame result) {
  return [
    result.purpose.wireValue,
    result.media.frame.unit,
    result.media.frame.localFrame,
  ];
}

/// Pre-incrementing monotonic clock (`{ now: () => ++now }`, first call → 1).
class _CountingClock implements PathSchedulerClock {
  int _now = 0;

  @override
  int now() => ++_now;
}

/// Faithful test substitute for the concrete `WorkerSampleFactory`.
class _FakeWorkerSampleFactory implements WorkerSampleFactory {
  _FakeWorkerSampleFactory({required this.timeline, required this.units});

  final DecodeTimeline timeline;
  final Map<String, int> units;

  @override
  DecoderWorkerSampleBatch createBatch(CreateWorkerSampleBatchInput input) {
    final timelineFrames = input.frames
        .map((request) => DecodeTimelineFrameRequest(
              unitId: request.unitId,
              unitFrame: request.unitFrame,
              unitFrameCount: units[request.unitId]!,
            ))
        .toList();
    final plan = timeline.planSampleBatch(timelineFrames);
    final samples = <DecoderWorkerSample>[];
    for (var index = 0; index < input.frames.length; index += 1) {
      final meta = plan.samples[index];
      samples.add(DecoderWorkerSample(
        ordinal: meta.ordinal,
        unitId: meta.unitId,
        unitInstance: meta.unitInstance,
        unitFrame: meta.unitFrame,
        unitFrameCount: meta.unitFrameCount,
        type: meta.unitFrame == 0
            ? EncodedVideoChunkType.key
            : EncodedVideoChunkType.delta,
        timestamp: meta.timestamp,
        duration: meta.duration,
        data: Uint8List(4).buffer,
      ));
    }
    final generation = plan.generation;
    plan.commit();
    return _FakeSampleBatch(generation, samples);
  }
}

class _FakeSampleBatch implements DecoderWorkerSampleBatch {
  _FakeSampleBatch(this.generation, this.samples);

  @override
  final int generation;

  @override
  final List<DecoderWorkerSample> samples;

  @override
  void release() {}
}

/// Options for the fake worker (path-scheduler.test.ts:789).
class FakeWorkerOptions {
  const FakeWorkerOptions({
    this.watchdog = false,
    this.retainOneStaleOutput = false,
    this.outputsPerWait = 1,
    this.integratedPathAsset = false,
  });

  final bool watchdog;
  final bool retainOneStaleOutput;
  final int outputsPerWait;
  final bool integratedPathAsset;
}

class _PendingFakeSample {
  const _PendingFakeSample(this.generation, this.sample);

  final int generation;
  final DecoderWorkerSample sample;
}

class _ActivationGate {
  _ActivationGate({required this.entered, required this.released});

  final void Function() entered;
  final Future<void> released;
}

typedef ActivationHandle = ({Future<void> entered, void Function() release});

class FakeWorker implements PathSchedulerWorkerAdapter {
  FakeWorker(FakeWorkerOptions options)
      : _watchdog = options.watchdog,
        _retainOneStaleOutput = options.retainOneStaleOutput,
        _outputsPerWait = options.outputsPerWait;

  @override
  int? activeGeneration;
  int maximumSubmittedBatch = 0;
  int abortCalls = 0;
  final bool _watchdog;
  final bool _retainOneStaleOutput;
  final int _outputsPerWait;
  final List<_PendingFakeSample> _pending = <_PendingFakeSample>[];
  final List<_FakeManagedFrame> _ready = <_FakeManagedFrame>[];
  final Set<_FakeManagedFrame> _open = <_FakeManagedFrame>{};
  int _acceptedSamples = 0;
  int _releasedFrames = 0;
  bool _staleRetained = false;
  _PendingFakeSample? _lastSubmitted;
  _ActivationGate? _activationGate;

  @override
  int get queuedFrames => _ready.length;

  @override
  int get openFrames => _open.length;

  ActivationHandle gateNextActivation() {
    if (_activationGate != null) {
      throw StateError('fake activation is already gated');
    }
    final enter = Completer<void>();
    final release = Completer<void>();
    _activationGate = _ActivationGate(
      entered: enter.complete,
      released: release.future,
    );
    return (entered: enter.future, release: release.complete);
  }

  @override
  Future<void> activateGeneration(int generation) async {
    final gate = _activationGate;
    if (gate != null) {
      _activationGate = null;
      gate.entered();
      await gate.released;
    }
    final previous = activeGeneration;
    activeGeneration = generation;
    for (final frame in [..._ready]) {
      if (frame.generation != generation) frame.close();
    }
    _ready.removeWhere((frame) => frame.closed);
    if (previous != null && _retainOneStaleOutput && !_staleRetained) {
      _PendingFakeSample? retained;
      for (final item in _pending) {
        if (item.generation == previous) {
          retained = item;
          break;
        }
      }
      retained ??=
          _lastSubmitted?.generation == previous ? _lastSubmitted : null;
      _pending.clear();
      if (retained != null) _pending.add(retained);
      _staleRetained = retained != null;
    } else {
      _pending.clear();
    }
  }

  @override
  Future<void> submit(int generation, List<DecoderWorkerSample> samples) async {
    if (generation != activeGeneration) {
      throw StateError('fake generation mismatch');
    }
    maximumSubmittedBatch = maximumSubmittedBatch > samples.length
        ? maximumSubmittedBatch
        : samples.length;
    for (final sample in samples) {
      final pending = _PendingFakeSample(generation, sample);
      _pending.add(pending);
      _lastSubmitted = pending;
      _acceptedSamples += 1;
    }
  }

  @override
  Future<void> abortGeneration(int generation) async {
    abortCalls += 1;
    _pending.removeWhere((item) => item.generation == generation);
    for (final frame in [..._open]) {
      if (frame.generation == generation) frame.close();
    }
    _ready.removeWhere((frame) => frame.closed);
    if (activeGeneration == generation) activeGeneration = null;
  }

  @override
  ManagedDecoderWorkerFrame? takeFrame() {
    return _ready.isEmpty ? null : _ready.removeAt(0);
  }

  @override
  Future<void> waitForFrames([
    int? minimum,
    DecoderWorkerWaitOptions? options,
  ]) async {
    if (_watchdog) {
      throw DecoderWorkerWatchdogError('injected path scheduler watchdog');
    }
    final min = minimum ?? 1;
    var released = 0;
    while (_pending.isNotEmpty &&
        (_ready.length < min || released < _outputsPerWait) &&
        released < _outputsPerWait) {
      final pending = _pending.removeAt(0);
      late final _FakeManagedFrame frame;
      frame = _FakeManagedFrame(pending, () {
        _open.remove(frame);
        _releasedFrames += 1;
      });
      _open.add(frame);
      _ready.add(frame);
      released += 1;
    }
  }

  @override
  Future<DecoderWorkerMetrics> snapshotMetrics() async {
    final generation = activeGeneration;
    final submittedFrames =
        _pending.where((item) => item.generation == generation).length;
    final leasedFrames =
        _open.where((frame) => frame.generation == generation).length;
    return DecoderWorkerMetrics(
      configureCalls: 1,
      resetCalls: 0,
      flushCalls: 0,
      boundaryFlushCalls: 0,
      acceptedSamples: _acceptedSamples,
      submittedChunks: _acceptedSamples,
      outputFrames: _acceptedSamples - _pending.length,
      deliveredFrames: _acceptedSamples - _pending.length,
      releasedFrames: _releasedFrames,
      staleFrames: 0,
      closedFrames: _releasedFrames,
      pendingSamples: 0,
      submittedFrames: submittedFrames,
      leasedFrames: leasedFrames,
      leasedDecodedBytes: leasedFrames * 128,
      decodeQueueSize: submittedFrames,
      activeGeneration: generation,
      nextSubmissionOrdinal: _acceptedSamples,
      nextOutputOrdinal: _acceptedSamples - _pending.length,
      errors: 0,
      disposed: false,
    );
  }
}

class _FakeVideoFrame implements VideoFrame {}

class _FakeManagedFrame implements ManagedDecoderWorkerFrame {
  _FakeManagedFrame(_PendingFakeSample pending, this._release)
      : frame = _FakeVideoFrame(),
        frameId = pending.sample.ordinal + 1,
        generation = pending.generation,
        ordinal = pending.sample.ordinal,
        unitId = pending.sample.unitId,
        unitInstance = pending.sample.unitInstance,
        unitFrame = pending.sample.unitFrame,
        timestamp = pending.sample.timestamp,
        duration = pending.sample.duration;

  @override
  final VideoFrame frame;
  @override
  final int frameId;
  @override
  final int generation;
  @override
  final int ordinal;
  @override
  final String unitId;
  @override
  final int unitInstance;
  @override
  final int unitFrame;
  @override
  final int timestamp;
  @override
  final int duration;
  @override
  final int decodedBytes = 128;
  @override
  int? get outputCallbackMicroseconds => null;

  final void Function() _release;
  bool _closed = false;

  @override
  bool get closed => _closed;

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _release();
  }
}

/// Test ergonomic: the TS suite closes a frame via `frame.frame.close()`, but
/// the `VideoFrame` platform seam has no `close`; the managed frame's own
/// [ManagedDecoderWorkerFrame.close] carries the identical release behavior.
extension on ManagedDecoderWorkerFrame {
  void closeFrame() => close();
}
