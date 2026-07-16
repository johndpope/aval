/// Port of `packages/player-web/src/runtime/worker-samples.test.ts` (1:1).
///
/// JS-only assertions with no Dart analog are dropped and noted inline:
/// `Object.keys(batch)` / `Object.isFrozen` (worker-samples.test.ts:105-108,219)
/// — the Dart batch is an immutable class with `List.unmodifiable` samples — and
/// the `structuredClone(..., {transfer})` neuter check
/// (worker-samples.test.ts:152-160) — Dart has no ArrayBuffer transfer; the
/// load-bearing distinctness/content/preservation assertions are kept.
library;

import 'dart:typed_data';

import 'package:aval_format/aval_format.dart'
    show AccessUnitRecord, AvcPackedAlphaRenditionV01, BitrateV01, ByteRange,
        Rect, RenditionV01, UnitV01;
import 'package:aval_player/aval_player.dart';
import 'package:test/test.dart';

import 'asset_test_fixture.dart';

const DecoderWorkerLimits limits = DecoderWorkerLimits(
  maxDecodeQueueSize: 8,
  maxPendingSamples: 12,
  maxOutstandingFrames: 12,
  maxDecodedBytes: 12 * 64 * 64 * 4,
);

void main() {
  group('WorkerSampleFactory', () {
    test('accepts the exact packed-alpha AVC profile on the shared sample path',
        () {
      final timeline = DecodeTimeline(
        const RationalFrameRate(numerator: 30, denominator: 1),
      );
      final catalog = _StaticCatalog(
        rendition: AvcPackedAlphaRenditionV01(
          id: 'packed',
          profile: 'avc-annexb-packed-alpha-v0',
          codec: 'avc1.42E020',
          codedWidth: 64,
          codedHeight: 144,
          colorRect: Rect(0, 0, 64, 64),
          alphaRect: Rect(0, 72, 64, 64),
          bitrate: const BitrateV01(average: 1000, peak: 2000),
        ),
      );

      expect(
        () => WorkerSampleFactory(WorkerSampleFactoryOptions(
          catalog: catalog,
          timeline: timeline,
          rendition: 'packed',
          limits: limits,
        )),
        returnsNormally,
      );
    });

    test('creates one closed batch across complete unit boundaries', () {
      final fixture = _makeFixture();

      final batch = fixture.factory.createBatch(CreateWorkerSampleBatchInput(
        frames: [frame('body', 0), frame('body', 1), frame('intro', 0)],
        pendingSamples: 0,
        outstandingFrames: 0,
      ));

      expect(batch.generation, 1);
      final actual = batch.samples
          .map((sample) => [
                sample.ordinal,
                sample.unitId,
                sample.unitInstance,
                sample.unitFrame,
                sample.unitFrameCount,
                sample.type.wireValue,
                sample.timestamp,
                sample.duration,
              ])
          .toList();
      expect(actual, [
        [0, 'body', 0, 0, 2, 'key', 0, 33333],
        [1, 'body', 0, 1, 2, 'delta', 33333, 33334],
        [2, 'intro', 1, 0, 2, 'key', 66667, 33333],
      ]);
    });

    test('continues a split occurrence and crosses into a new loop instance',
        () {
      final fixture = _makeFixture();

      final first = fixture.factory.createBatch(CreateWorkerSampleBatchInput(
        frames: [frame('body', 0)],
        pendingSamples: 0,
        outstandingFrames: 0,
      ));
      final second = fixture.factory.createBatch(CreateWorkerSampleBatchInput(
        frames: [frame('body', 1), frame('body', 0)],
        pendingSamples: 0,
        outstandingFrames: 0,
      ));

      expect(first.samples.map(identity), [
        [0, 'body', 0, 0],
      ]);
      expect(second.samples.map(identity), [
        [1, 'body', 0, 1],
        [2, 'body', 1, 0],
      ]);
    });

    test(
        'allocates one distinct exact-length buffer and preserves catalog bytes',
        () {
      final fixture = _makeFixture();
      final expected = [0, 1]
          .map((localFrame) => Uint8List.view(
              fixture.catalog.copySample('opaque', 'body', localFrame)))
          .toList();
      final batch = fixture.factory.createBatch(CreateWorkerSampleBatchInput(
        frames: [frame('body', 0), frame('body', 1)],
        pendingSamples: 0,
        outstandingFrames: 0,
      ));

      expect(batch.samples.map((sample) => sample.data).toSet().length, 2);
      for (var index = 0; index < batch.samples.length; index += 1) {
        final data = Uint8List.view(batch.samples[index].data);
        expect(data.length, expected[index].length);
        expect(data, expected[index]);
      }

      // Catalog copies are independent: re-copying yields the same bytes.
      expect(
        Uint8List.view(fixture.catalog.copySample('opaque', 'body', 0)),
        expected[0],
      );
      expect(
        Uint8List.view(fixture.catalog.copySample('opaque', 'body', 1)),
        expected[1],
      );
    });

    test(
        'claims exact transfer bytes before copying and releases after transfer',
        () {
      final fixture = _makeFixture();
      final events = <String>[];
      var activeBytes = 0;
      var releases = 0;
      final resourceHost = _InlineResourceHost((byteLength) {
        events.add('claim:$byteLength');
        activeBytes += byteLength;
        var released = false;
        return _InlineTransferLease(() {
          if (released) return;
          released = true;
          activeBytes -= byteLength;
          releases += 1;
        });
      });
      final factory = WorkerSampleFactory(WorkerSampleFactoryOptions(
        catalog: _CatalogView(
          fixture.catalog,
          copySample: (rendition, unit, localFrame) {
            events.add('copy');
            return fixture.catalog.copySample(rendition, unit, localFrame);
          },
        ),
        timeline: fixture.timeline,
        rendition: 'opaque',
        limits: limits,
        resourceHost: resourceHost,
      ));
      final expectedBytes =
          fixture.catalog.records.require('opaque', 'body', 0).range.length +
              fixture.catalog.records.require('opaque', 'body', 1).range.length;

      final batch = factory.createBatch(CreateWorkerSampleBatchInput(
        frames: [frame('body', 0), frame('body', 1)],
        pendingSamples: 0,
        outstandingFrames: 0,
      ));

      expect(events, ['claim:$expectedBytes', 'copy', 'copy']);
      expect(activeBytes, expectedBytes);
      batch.release();
      batch.release();
      expect(activeBytes, 0);
      expect(releases, 1);
    });

    test('rejects a transfer one byte over budget before any sample allocation',
        () {
      final fixture = _makeFixture();
      var copyCalls = 0;
      final expectedBytes =
          fixture.catalog.records.require('opaque', 'body', 0).range.length +
              fixture.catalog.records.require('opaque', 'body', 1).range.length;
      final claims = <int>[];
      final factory = WorkerSampleFactory(WorkerSampleFactoryOptions(
        catalog: _CatalogView(
          fixture.catalog,
          copySample: (rendition, unit, localFrame) {
            copyCalls += 1;
            return fixture.catalog.copySample(rendition, unit, localFrame);
          },
        ),
        timeline: fixture.timeline,
        rendition: 'opaque',
        limits: limits,
        resourceHost: _InlineResourceHost((byteLength) {
          claims.add(byteLength);
          if (byteLength > expectedBytes - 1) {
            throw RangeError('injected one-byte-over transfer pressure');
          }
          return _InlineTransferLease(() {});
        }),
      ));
      final before = fixture.timeline.snapshot();

      expect(
        () => factory.createBatch(CreateWorkerSampleBatchInput(
          frames: [frame('body', 0), frame('body', 1)],
          pendingSamples: 0,
          outstandingFrames: 0,
        )),
        throwsA(isA<RangeError>().having(
          (error) => error.toString(),
          'message',
          contains('one-byte-over transfer pressure'),
        )),
      );

      expect(claims, [expectedBytes]);
      expect(copyCalls, 0);
      expect(fixture.timeline.snapshot(), before);
    });

    test('releases a transfer claim when a later sample copy fails', () {
      final fixture = _makeFixture();
      var activeClaims = 0;
      final factory = WorkerSampleFactory(WorkerSampleFactoryOptions(
        catalog: _CatalogView(
          fixture.catalog,
          copySample: (rendition, unit, localFrame) {
            if (localFrame == 1) throw StateError('injected copy failure');
            return fixture.catalog.copySample(rendition, unit, localFrame);
          },
        ),
        timeline: fixture.timeline,
        rendition: 'opaque',
        limits: limits,
        resourceHost: _InlineResourceHost((byteLength) {
          activeClaims += 1;
          return _InlineTransferLease(() => activeClaims -= 1);
        }),
      ));

      expect(
        () => factory.createBatch(CreateWorkerSampleBatchInput(
          frames: [frame('body', 0), frame('body', 1)],
          pendingSamples: 0,
          outstandingFrames: 0,
        )),
        throwsA(isA<StateError>()),
      );
      expect(activeClaims, 0);
      expect(fixture.timeline.snapshot().nextOrdinal, 0);
    });

    test('validates the complete batch before copying or advancing the timeline',
        () {
      final fixture = _makeFixture();
      var copyCalls = 0;
      final factory = WorkerSampleFactory(WorkerSampleFactoryOptions(
        catalog: _CatalogView(
          fixture.catalog,
          copySample: (rendition, unit, localFrame) {
            copyCalls += 1;
            return fixture.catalog.copySample(rendition, unit, localFrame);
          },
        ),
        timeline: fixture.timeline,
        rendition: 'opaque',
        limits: limits,
      ));
      final before = fixture.timeline.snapshot();

      expect(
        () => factory.createBatch(CreateWorkerSampleBatchInput(
          frames: [frame('body', 0), frame('missing', 0)],
          pendingSamples: 0,
          outstandingFrames: 0,
        )),
        throwsA(anything),
      );
      expect(copyCalls, 0);
      expect(fixture.timeline.snapshot(), before);

      expect(
        () => factory.createBatch(CreateWorkerSampleBatchInput(
          frames: [frame('body', 1)],
          pendingSamples: 0,
          outstandingFrames: 0,
        )),
        throwsA(isA<RangeError>().having(
          (error) => error.toString(),
          'message',
          contains('frame zero'),
        )),
      );
      expect(copyCalls, 0);
      expect(fixture.timeline.snapshot(), before);
    });

    test('does not advance the timeline when a later payload allocation fails',
        () {
      final fixture = _makeFixture();
      var copyCalls = 0;
      final factory = WorkerSampleFactory(WorkerSampleFactoryOptions(
        catalog: _CatalogView(
          fixture.catalog,
          copySample: (rendition, unit, localFrame) {
            copyCalls += 1;
            if (localFrame == 1) {
              throw RangeError('injected sample allocation failure');
            }
            return fixture.catalog.copySample(rendition, unit, localFrame);
          },
        ),
        timeline: fixture.timeline,
        rendition: 'opaque',
        limits: limits,
      ));
      final before = fixture.timeline.snapshot();

      expect(
        () => factory.createBatch(CreateWorkerSampleBatchInput(
          frames: [frame('body', 0), frame('body', 1)],
          pendingSamples: 0,
          outstandingFrames: 0,
        )),
        throwsA(isA<RangeError>().having(
          (error) => error.toString(),
          'message',
          contains('injected sample allocation failure'),
        )),
      );
      expect(copyCalls, 2);
      expect(fixture.timeline.snapshot(), before);
    });

    test('enforces pending and outstanding credit before any payload copy', () {
      final fixture = _makeFixture();
      var copyCalls = 0;
      final factory = WorkerSampleFactory(WorkerSampleFactoryOptions(
        catalog: _CatalogView(
          fixture.catalog,
          copySample: (rendition, unit, localFrame) {
            copyCalls += 1;
            return fixture.catalog.copySample(rendition, unit, localFrame);
          },
        ),
        timeline: fixture.timeline,
        rendition: 'opaque',
        limits: limits,
      ));
      final frames = [frame('body', 0), frame('body', 1)];

      final overCreditInputs = [
        CreateWorkerSampleBatchInput(
            frames: frames, pendingSamples: 11, outstandingFrames: 0),
        CreateWorkerSampleBatchInput(
            frames: frames, pendingSamples: 0, outstandingFrames: 11),
        CreateWorkerSampleBatchInput(
            frames: alternatingBodyFrames(13),
            pendingSamples: 0,
            outstandingFrames: 0),
      ];
      for (final input in overCreditInputs) {
        expect(
          () => factory.createBatch(input),
          throwsA(isA<RangeError>().having(
            (error) => error.toString(),
            'message',
            contains('limit'),
          )),
        );
      }
      expect(copyCalls, 0);
      expect(fixture.timeline.snapshot().nextOrdinal, 0);

      expect(
        factory
            .createBatch(CreateWorkerSampleBatchInput(
              frames: frames,
              pendingSamples: 10,
              outstandingFrames: 10,
            ))
            .samples,
        hasLength(2),
      );
    });

    test('rejects hostile record lengths before copying sample bytes', () {
      final fixture = _makeFixture();
      final firstRecord = fixture.catalog.records.require('opaque', 'body', 0);
      var copyCalls = 0;
      final hostile = _CatalogView(
        fixture.catalog,
        records: _StaticRecordIndex(RuntimeCatalogAccessUnit(
          rendition: firstRecord.rendition,
          unit: firstRecord.unit,
          localFrame: firstRecord.localFrame,
          ordinal: firstRecord.ordinal,
          record: AccessUnitRecord(
            payloadOffset: firstRecord.record.payloadOffset,
            payloadLength: maxSafeInteger + 1,
            unitIndex: firstRecord.record.unitIndex,
            renditionIndex: firstRecord.record.renditionIndex,
            key: firstRecord.record.key,
            frameIndex: firstRecord.record.frameIndex,
          ),
          range: ByteRange(
            offset: firstRecord.range.offset,
            length: maxSafeInteger + 1,
          ),
          blobKey: firstRecord.blobKey,
          blobRange: firstRecord.blobRange,
          relativeRange: firstRecord.relativeRange,
        )),
        copySample: (rendition, unit, localFrame) {
          copyCalls += 1;
          return fixture.catalog.copySample(rendition, unit, localFrame);
        },
      );
      final factory = WorkerSampleFactory(WorkerSampleFactoryOptions(
        catalog: hostile,
        timeline: fixture.timeline,
        rendition: 'opaque',
        limits: limits,
      ));

      expect(
        () => factory.createBatch(CreateWorkerSampleBatchInput(
          frames: [frame('body', 0)],
          pendingSamples: 0,
          outstandingFrames: 0,
        )),
        throwsA(isA<RangeError>().having(
          (error) => error.toString(),
          'message',
          contains('sample byte length'),
        )),
      );
      expect(copyCalls, 0);
      expect(fixture.timeline.snapshot().nextOrdinal, 0);
    });

    test(
        'resets occurrence identity but not ordinal or time on generation change',
        () {
      final fixture = _makeFixture();
      final first = fixture.factory.createBatch(CreateWorkerSampleBatchInput(
        frames: [frame('body', 0), frame('body', 1)],
        pendingSamples: 0,
        outstandingFrames: 0,
      ));
      expect(fixture.timeline.activateNextGeneration(), 2);
      final beforeBad = fixture.timeline.snapshot();

      expect(
        () => fixture.factory.createBatch(CreateWorkerSampleBatchInput(
          frames: [frame('body', 1)],
          pendingSamples: 0,
          outstandingFrames: 0,
        )),
        throwsA(isA<RangeError>().having(
          (error) => error.toString(),
          'message',
          contains('frame zero'),
        )),
      );
      expect(fixture.timeline.snapshot(), beforeBad);

      final second = fixture.factory.createBatch(CreateWorkerSampleBatchInput(
        frames: [frame('body', 0)],
        pendingSamples: 0,
        outstandingFrames: 0,
      ));
      expect(second.generation, 2);
      expect(second.samples.map(identity), [
        [2, 'body', 0, 0],
      ]);
      expect(
        second.samples[0].timestamp,
        greaterThan(first.samples.last.timestamp),
      );
    });

    test('rejects a copied buffer whose runtime length differs from its record',
        () {
      final fixture = _makeFixture();
      final factory = WorkerSampleFactory(WorkerSampleFactoryOptions(
        catalog: _CatalogView(
          fixture.catalog,
          copySample: (rendition, unit, localFrame) => Uint8List(1).buffer,
        ),
        timeline: fixture.timeline,
        rendition: 'opaque',
        limits: limits,
      ));

      expect(
        () => factory.createBatch(CreateWorkerSampleBatchInput(
          frames: [frame('body', 0)],
          pendingSamples: 0,
          outstandingFrames: 0,
        )),
        throwsA(isA<RangeError>().having(
          (error) => error.toString(),
          'message',
          contains('exact record length'),
        )),
      );
      expect(fixture.timeline.snapshot().nextOrdinal, 0);
    });
  });
}

class _Fixture {
  _Fixture(this.catalog, this.timeline, this.factory);

  final RuntimeAssetCatalog catalog;
  final DecodeTimeline timeline;
  final WorkerSampleFactory factory;
}

_Fixture _makeFixture() {
  final catalog = installRuntimeAssetCatalog(createOpaqueTestAsset());
  final timeline = DecodeTimeline(RationalFrameRate(
    numerator: catalog.manifest.frameRate.numerator,
    denominator: catalog.manifest.frameRate.denominator,
  ));
  timeline.activateNextGeneration();
  return _Fixture(catalog, timeline, _createFactory(catalog, timeline));
}

WorkerSampleFactory _createFactory(
  WorkerSampleCatalog catalog,
  DecodeTimeline timeline,
) {
  return WorkerSampleFactory(WorkerSampleFactoryOptions(
    catalog: catalog,
    timeline: timeline,
    rendition: 'opaque',
    limits: limits,
  ));
}

WorkerSampleFrameRequest frame(String unitId, int unitFrame) =>
    WorkerSampleFrameRequest(unitId: unitId, unitFrame: unitFrame);

List<WorkerSampleFrameRequest> alternatingBodyFrames(int length) =>
    List.generate(length, (index) => frame('body', index % 2));

List<Object> identity(DecoderWorkerSample sample) =>
    [sample.ordinal, sample.unitId, sample.unitInstance, sample.unitFrame];

/// A [WorkerSampleCatalog] delegating to a base with optional overrides.
class _CatalogView implements WorkerSampleCatalog {
  _CatalogView(
    this._base, {
    ByteBuffer Function(String, String, int)? copySample,
    RuntimeCatalogRecordIndex? records,
  })  : _copySampleOverride = copySample,
        _recordsOverride = records;

  final WorkerSampleCatalog _base;
  final ByteBuffer Function(String, String, int)? _copySampleOverride;
  final RuntimeCatalogRecordIndex? _recordsOverride;

  @override
  RuntimeCatalogIdIndex<RenditionV01> get renditions => _base.renditions;

  @override
  RuntimeCatalogIdIndex<UnitV01> get units => _base.units;

  @override
  RuntimeCatalogRecordIndex get records => _recordsOverride ?? _base.records;

  @override
  ByteBuffer copySample(String rendition, String unit, int localFrame) =>
      (_copySampleOverride ?? _base.copySample)(rendition, unit, localFrame);
}

/// A [WorkerSampleCatalog] whose only working lookup is `renditions.require`.
class _StaticCatalog implements WorkerSampleCatalog {
  _StaticCatalog({required RenditionV01 rendition})
      : renditions = _StaticIdIndex<RenditionV01>(rendition);

  @override
  final RuntimeCatalogIdIndex<RenditionV01> renditions;

  @override
  RuntimeCatalogIdIndex<UnitV01> get units =>
      _ThrowingIdIndex<UnitV01>('unused');

  @override
  RuntimeCatalogRecordIndex get records => _ThrowingRecordIndex();

  @override
  ByteBuffer copySample(String rendition, String unit, int localFrame) =>
      Uint8List(0).buffer;
}

class _StaticIdIndex<T> implements RuntimeCatalogIdIndex<T> {
  _StaticIdIndex(this._value);

  final T _value;

  @override
  int get size => 1;
  @override
  T? get(String id) => _value;
  @override
  T require(String id) => _value;
  @override
  List<String> keys() => throw UnimplementedError();
  @override
  List<T> values() => throw UnimplementedError();
}

class _ThrowingIdIndex<T> implements RuntimeCatalogIdIndex<T> {
  _ThrowingIdIndex(this._message);
  final String _message;
  @override
  int get size => throw UnimplementedError();
  @override
  T? get(String id) => throw StateError(_message);
  @override
  T require(String id) => throw StateError(_message);
  @override
  List<String> keys() => throw UnimplementedError();
  @override
  List<T> values() => throw UnimplementedError();
}

class _StaticRecordIndex implements RuntimeCatalogRecordIndex {
  _StaticRecordIndex(this._value);

  final RuntimeCatalogAccessUnit _value;

  @override
  int get size => 1;
  @override
  RuntimeCatalogAccessUnit? get(String rendition, String unit, int localFrame) =>
      _value;
  @override
  RuntimeCatalogAccessUnit require(
          String rendition, String unit, int localFrame) =>
      _value;
  @override
  List<RuntimeCatalogAccessUnit> values() => throw UnimplementedError();
}

class _ThrowingRecordIndex implements RuntimeCatalogRecordIndex {
  @override
  int get size => throw UnimplementedError();
  @override
  RuntimeCatalogAccessUnit? get(String rendition, String unit, int localFrame) =>
      throw StateError('unused');
  @override
  RuntimeCatalogAccessUnit require(
          String rendition, String unit, int localFrame) =>
      throw StateError('unused');
  @override
  List<RuntimeCatalogAccessUnit> values() => throw UnimplementedError();
}

class _InlineResourceHost implements WorkerSampleResourceHost {
  _InlineResourceHost(this._claim);

  final WorkerSampleTransferLease Function(int) _claim;

  @override
  WorkerSampleTransferLease claim(int byteLength) => _claim(byteLength);
}

class _InlineTransferLease implements WorkerSampleTransferLease {
  _InlineTransferLease(this._release);

  final void Function() _release;

  @override
  void release() => _release();
}
