// Dart port of packages/format/test/access-unit-index.test.ts.
import 'dart:typed_data';

import 'package:aval_format/src/access_unit_index.dart';
import 'package:aval_format/src/checked_integer.dart' show writeUint32LE, writeUint64LE, maxSafeInteger;
import 'package:aval_format/src/errors.dart';
import 'package:aval_format/src/model.dart';
import 'package:test/test.dart';

final String _sha256Zeros = '0'.padRight(64, '0');

CompiledManifestV01 _manifestWith(RenditionV01 rendition, UnitV01 unit) => CompiledManifestV01(
      generator: 'test',
      canvas: const CanvasV01(width: 1, height: 1, fit: 'contain', pixelAspect: [1, 1]),
      frameRate: const RationalV01(numerator: 30, denominator: 1),
      renditions: [rendition],
      units: [unit],
      initialState: 'a',
      states: const [],
      edges: const [],
      bindings: const [],
      readiness: const ReadinessV01(bootstrapUnits: [], immediateEdges: []),
      limits: const DeclaredLimitsV01(
        maxCompiledBytes: maxSafeInteger,
        maxRuntimeBytes: maxSafeInteger,
        decodedPixelBytes: 0,
        persistentCacheBytes: 0,
        runtimeWorkingSetBytes: 0,
      ),
    );

final CompiledManifestV01 avcManifest = _manifestWith(
  AvcOpaqueRenditionV01(
    id: 'avc',
    profile: 'avc-annexb-opaque-v0',
    codec: 'avc1.42E00A',
    codedWidth: 16,
    codedHeight: 16,
    colorRect: const Rect(0, 0, 16, 16),
    bitrate: const BitrateV01(average: 1, peak: 1),
  ),
  BodyUnitV01(
    id: 'body',
    frameCount: 2,
    playback: 'finite',
    ports: const [],
    samples: [
      SampleSpanV01(rendition: 'avc', sampleStart: 0, sampleCount: 2, sha256: _sha256Zeros),
    ],
  ),
);

final CompiledManifestV01 referenceManifest = _manifestWith(
  const ReferenceRgbaRenditionV01(id: 'reference', codedWidth: 1, codedHeight: 1),
  BodyUnitV01(
    id: 'body',
    frameCount: 2,
    playback: 'finite',
    ports: const [],
    samples: [
      SampleSpanV01(rendition: 'reference', sampleStart: 0, sampleCount: 2, sha256: _sha256Zeros),
    ],
  ),
);

final List<AccessUnitRecord> kRecords = [
  const AccessUnitRecord(
    payloadOffset: 128,
    payloadLength: 4,
    unitIndex: 0,
    renditionIndex: 0,
    key: true,
    frameIndex: 0,
  ),
  const AccessUnitRecord(
    payloadOffset: 132,
    payloadLength: 5,
    unitIndex: 0,
    renditionIndex: 0,
    key: false,
    frameIndex: 1,
  ),
];

const String goldenHex = '41564c49200000000200000000000000'
    '8000000000000000040000000000000000000100000000000000000000000000'
    '8400000000000000050000000000000000000000010000000000000000000000';

String _hex(Uint8List bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

AccessUnitRecord _withKey(AccessUnitRecord record, bool key) => AccessUnitRecord(
      payloadOffset: record.payloadOffset,
      payloadLength: record.payloadLength,
      unitIndex: record.unitIndex,
      renditionIndex: record.renditionIndex,
      key: key,
      frameIndex: record.frameIndex,
    );

FormatError _expectFormatError(dynamic Function() operation, FormatErrorCode code) {
  try {
    operation();
  } on FormatError catch (error) {
    expect(error.code, code);
    return error;
  }
  fail('expected operation to throw');
}

void main() {
  group('version-0.1 access-unit index', () {
    test('encodes the exact 16 + 32N canonical bytes', () {
      final bytes = encodeAccessUnitIndex(kRecords, avcManifest);
      expect(bytes.length, 80);
      expect(_hex(bytes), goldenHex);
    });

    test('parses detached numeric records', () {
      final bytes = encodeAccessUnitIndex(kRecords, avcManifest);
      final parsed = parseAccessUnitIndex(bytes, avcManifest);
      expect(parsed.length, kRecords.length);
      for (var i = 0; i < parsed.length; i += 1) {
        expect(parsed[i].payloadOffset, kRecords[i].payloadOffset);
        expect(parsed[i].payloadLength, kRecords[i].payloadLength);
        expect(parsed[i].key, kRecords[i].key);
        expect(parsed[i].frameIndex, kRecords[i].frameIndex);
      }
      bytes.fillRange(0, bytes.length, 0);
      expect(parsed[0].payloadOffset, kRecords[0].payloadOffset);
    });

    test('supports an unaligned view and reads no adjacent bytes', () {
      final index = encodeAccessUnitIndex(kRecords, avcManifest);
      final storage = Uint8List(index.length + 7)..fillRange(0, index.length + 7, 0xa5);
      final view = Uint8List.sublistView(storage, 3, 3 + index.length);
      view.setRange(0, index.length, index);
      final parsed = parseAccessUnitIndex(view, avcManifest);
      expect(parsed.length, kRecords.length);
      expect(storage.sublist(0, 3), [0xa5, 0xa5, 0xa5]);
      expect(storage.sublist(3 + index.length), [0xa5, 0xa5, 0xa5, 0xa5]);
    });

    test('rejects every truncation and any trailing byte before record allocation', () {
      final bytes = encodeAccessUnitIndex(kRecords, avcManifest);
      for (var length = 0; length < bytes.length; length += 1) {
        _expectFormatError(
          () => parseAccessUnitIndex(Uint8List.sublistView(bytes, 0, length), avcManifest),
          FormatErrorCode.indexInvalid,
        );
      }
      final trailing = Uint8List(bytes.length + 1)..setRange(0, bytes.length, bytes);
      _expectFormatError(() => parseAccessUnitIndex(trailing, avcManifest), FormatErrorCode.indexInvalid);
    });

    test('rejects magic, record-size, header-reserved, and record-reserved mutations', () {
      final offsets = [0, 4, 6, 12, 16 + 24];
      for (final offset in offsets) {
        final bytes = encodeAccessUnitIndex(kRecords, avcManifest);
        bytes[offset] = bytes[offset] ^ 1;
        _expectFormatError(() => parseAccessUnitIndex(bytes, avcManifest), FormatErrorCode.indexInvalid);
      }
    });

    test('rejects unknown flag bits and non-key unit entry frames', () {
      final unknownFlag = encodeAccessUnitIndex(kRecords, avcManifest);
      unknownFlag[16 + 18] = 2;
      _expectFormatError(() => parseAccessUnitIndex(unknownFlag, avcManifest), FormatErrorCode.indexInvalid);

      final nonKeyEntry = encodeAccessUnitIndex(kRecords, avcManifest);
      nonKeyEntry[16 + 18] = 0;
      _expectFormatError(() => parseAccessUnitIndex(nonKeyEntry, avcManifest), FormatErrorCode.indexInvalid);
    });

    test('requires every reference-rgba-v0 record to be key', () {
      _expectFormatError(
        () => encodeAccessUnitIndex(kRecords, referenceManifest),
        FormatErrorCode.indexInvalid,
      );
      final allKey = kRecords.map((record) => _withKey(record, true)).toList();
      final parsed = parseAccessUnitIndex(encodeAccessUnitIndex(allKey, referenceManifest), referenceManifest);
      expect(parsed.every((record) => record.key), true);
    });

    test('rejects zero and lower-budget sample lengths without a product ceiling', () {
      final zero = encodeAccessUnitIndex(kRecords, avcManifest);
      writeUint32LE(zero, 16 + 8, 0);
      _expectFormatError(() => parseAccessUnitIndex(zero, avcManifest), FormatErrorCode.indexInvalid);

      final formerlyOversized = encodeAccessUnitIndex(kRecords, avcManifest);
      writeUint32LE(formerlyOversized, 16 + 8, 2 * 1024 * 1024 + 1);
      expect(
        parseAccessUnitIndex(formerlyOversized, avcManifest)[0].payloadLength,
        2 * 1024 * 1024 + 1,
      );

      final lowered = encodeAccessUnitIndex(kRecords, avcManifest);
      _expectFormatError(
        () => parseAccessUnitIndex(lowered, avcManifest, const FormatOptions(budgets: {'maxSampleBytes': 4})),
        FormatErrorCode.budgetExceeded,
      );
    });

    test('rejects unsafe and caller-over-budget payload offsets', () {
      final unsafe = encodeAccessUnitIndex(kRecords, avcManifest);
      writeUint64LE(unsafe, 16, BigInt.from(maxSafeInteger) + BigInt.one);
      _expectFormatError(() => parseAccessUnitIndex(unsafe, avcManifest), FormatErrorCode.integerUnsafe);

      final overFormerBudget = encodeAccessUnitIndex(kRecords, avcManifest);
      writeUint64LE(overFormerBudget, 16, 32 * 1024 * 1024 + 1);
      expect(
        parseAccessUnitIndex(overFormerBudget, avcManifest)[0].payloadOffset,
        32 * 1024 * 1024 + 1,
      );
      _expectFormatError(
        () => parseAccessUnitIndex(
          overFormerBudget,
          avcManifest,
          const FormatOptions(budgets: {'maxFileBytes': 32 * 1024 * 1024}),
        ),
        FormatErrorCode.budgetExceeded,
      );
    });

    test('cross-checks record count, canonical order, and frame coverage', () {
      final wrongCount = Uint8List.sublistView(encodeAccessUnitIndex(kRecords, avcManifest), 0, 48);
      writeUint32LE(wrongCount, 8, 1);
      _expectFormatError(() => parseAccessUnitIndex(wrongCount, avcManifest), FormatErrorCode.indexInvalid);

      final wrongFrame = encodeAccessUnitIndex(kRecords, avcManifest);
      writeUint32LE(wrongFrame, 16 + 20, 1);
      _expectFormatError(() => parseAccessUnitIndex(wrongFrame, avcManifest), FormatErrorCode.indexInvalid);

      final wrongUnit = encodeAccessUnitIndex(kRecords, avcManifest);
      writeUint32LE(wrongUnit, 16 + 12, 1);
      _expectFormatError(() => parseAccessUnitIndex(wrongUnit, avcManifest), FormatErrorCode.indexInvalid);
    });

    test('allows later AVC samples to carry or omit the structural key bit', () {
      final allKey = kRecords.map((record) => _withKey(record, true)).toList();
      final parsed = parseAccessUnitIndex(encodeAccessUnitIndex(allKey, avcManifest), avcManifest);
      expect(parsed.every((record) => record.key), true);
    });

    test('round-trips an index above the former 4 MiB scale', () {
      const recordCount = 131073;
      final manifest = _manifestWith(
        AvcOpaqueRenditionV01(
          id: 'avc',
          profile: 'avc-annexb-opaque-v0',
          codec: 'avc1.42E00A',
          codedWidth: 16,
          codedHeight: 16,
          colorRect: const Rect(0, 0, 16, 16),
          bitrate: const BitrateV01(average: 1, peak: 1),
        ),
        BodyUnitV01(
          id: 'body',
          frameCount: recordCount,
          playback: 'finite',
          ports: const [],
          samples: [
            SampleSpanV01(rendition: 'avc', sampleStart: 0, sampleCount: recordCount, sha256: _sha256Zeros),
          ],
        ),
      );
      final records = List<AccessUnitRecord>.generate(
        recordCount,
        (frameIndex) => AccessUnitRecord(
          payloadOffset: 8000000 + frameIndex,
          payloadLength: 1,
          unitIndex: 0,
          renditionIndex: 0,
          key: frameIndex == 0,
          frameIndex: frameIndex,
        ),
      );

      final bytes = encodeAccessUnitIndex(records, manifest);
      final parsed = parseAccessUnitIndex(bytes, manifest);

      expect(bytes.length, greaterThan(4 * 1024 * 1024));
      expect(parsed.length, recordCount);
      expect(parsed.last.frameIndex, recordCount - 1);
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('honors record/index budgets before allocating record results', () {
      final bytes = encodeAccessUnitIndex(kRecords, avcManifest);
      _expectFormatError(
        () => parseAccessUnitIndex(bytes, avcManifest, const FormatOptions(budgets: {'maxSampleRecords': 1})),
        FormatErrorCode.budgetExceeded,
      );
      _expectFormatError(
        () => parseAccessUnitIndex(bytes, avcManifest, const FormatOptions(budgets: {'maxIndexBytes': 79})),
        FormatErrorCode.budgetExceeded,
      );
    });
  });
}
