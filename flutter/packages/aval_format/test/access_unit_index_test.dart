// Dart port of packages/format/test/access-unit-index.test.ts.
import 'dart:typed_data';

import 'package:aval_format/src/access_unit_index.dart';
import 'package:aval_format/src/checked_integer.dart' show writeUint32LE, writeUint64LE, maxSafeInteger;
import 'package:aval_format/src/errors.dart';
import 'package:aval_format/src/model.dart';
import 'package:test/test.dart';

final String _sha256Zeros = '0'.padRight(64, '0');

CompiledManifest _manifestWith({
  required ProductionRendition rendition,
  required Unit unit,
}) =>
    CompiledManifest(
      generator: 'test',
      codec: rendition.codec,
      bitstream: 'annex-b',
      layout: 'opaque',
      canvas: Canvas(
        width: rendition.codedWidth,
        height: rendition.codedHeight,
        fit: 'contain',
        pixelAspect: const [1, 1],
      ),
      frameRate: const Rational(numerator: 30, denominator: 1),
      renditions: [rendition],
      units: [unit],
      initialState: 'a',
      states: const [],
      edges: const [],
      bindings: const [],
      readiness: const Readiness(bootstrapUnits: [], immediateEdges: []),
      limits: const DeclaredLimits(
        maxCompiledBytes: maxSafeInteger,
        maxRuntimeBytes: maxSafeInteger,
        decodedPixelBytes: 0,
        persistentCacheBytes: 0,
        runtimeWorkingSetBytes: 0,
      ),
    );

ProductionRendition _videoRendition() => ProductionRendition(
      id: 'video',
      codec: 'avc1.42E00A',
      bitDepth: 8,
      codedWidth: 16,
      codedHeight: 16,
      alphaLayout: OpaqueAlphaLayout(colorRect: const Rect(0, 0, 16, 16)),
      bitrate: const Bitrate(average: 1, peak: 1),
    );

Unit _bodyUnit({required int frameCount, required int chunkCount}) => BodyUnit(
      id: 'body',
      frameCount: frameCount,
      playback: 'finite',
      ports: const [],
      chunks: [
        UnitChunkSpan(
          rendition: 'video',
          chunkStart: 0,
          chunkCount: chunkCount,
          frameCount: frameCount,
          sha256: _sha256Zeros,
        ),
      ],
    );

final CompiledManifest manifest = _manifestWith(
  rendition: _videoRendition(),
  unit: _bodyUnit(frameCount: 2, chunkCount: 2),
);

final List<EncodedChunkRecord> kRecords = [
  const EncodedChunkRecord(
    byteOffset: 128,
    byteLength: 4,
    presentationTimestamp: 1,
    duration: 1,
    randomAccess: true,
    displayedFrameCount: 1,
  ),
  const EncodedChunkRecord(
    byteOffset: 132,
    byteLength: 5,
    presentationTimestamp: 0,
    duration: 1,
    randomAccess: false,
    displayedFrameCount: 1,
  ),
];

const String goldenHex = '41564c49300000000200000000000000'
    '800000000000000004000000010000000100000000000000010000000000000001000000000000000000000000000000'
    '840000000000000005000000010000000000000000000000010000000000000000000000000000000000000000000000';

String _hex(Uint8List bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

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
  group('version-1.0 encoded-chunk index', () {
    test('encodes the exact 16 + 48N canonical bytes', () {
      final bytes = encodeEncodedChunkIndex(kRecords, manifest);
      expect(bytes.length, 112);
      expect(_hex(bytes), goldenHex);
    });

    test('preserves decode order independently from presentation timestamps', () {
      final bytes = encodeEncodedChunkIndex(kRecords, manifest);
      final parsed = parseEncodedChunkIndex(bytes, manifest);
      expect(parsed.length, kRecords.length);
      for (var i = 0; i < parsed.length; i += 1) {
        expect(parsed[i].byteOffset, kRecords[i].byteOffset);
        expect(parsed[i].byteLength, kRecords[i].byteLength);
        expect(parsed[i].presentationTimestamp, kRecords[i].presentationTimestamp);
        expect(parsed[i].duration, kRecords[i].duration);
        expect(parsed[i].randomAccess, kRecords[i].randomAccess);
        expect(parsed[i].displayedFrameCount, kRecords[i].displayedFrameCount);
      }
      expect(parsed.map((r) => r.presentationTimestamp).toList(), [1, 0]);
      bytes.fillRange(0, bytes.length, 0);
      expect(parsed[0].byteOffset, kRecords[0].byteOffset);
    });

    test('supports hidden chunks and multiple chunks per displayed frame timeline', () {
      final hiddenManifest = _manifestWith(
        rendition: _videoRendition(),
        unit: _bodyUnit(frameCount: 1, chunkCount: 2),
      );
      final records = <EncodedChunkRecord>[
        EncodedChunkRecord(
          byteOffset: kRecords[0].byteOffset,
          byteLength: kRecords[0].byteLength,
          presentationTimestamp: kRecords[0].presentationTimestamp,
          duration: 0,
          randomAccess: kRecords[0].randomAccess,
          displayedFrameCount: 0,
        ),
        EncodedChunkRecord(
          byteOffset: kRecords[1].byteOffset,
          byteLength: kRecords[1].byteLength,
          presentationTimestamp: 0,
          duration: kRecords[1].duration,
          randomAccess: kRecords[1].randomAccess,
          displayedFrameCount: kRecords[1].displayedFrameCount,
        ),
      ];
      final parsed = parseEncodedChunkIndex(
        encodeEncodedChunkIndex(records, hiddenManifest),
        hiddenManifest,
      );
      expect(parsed.length, records.length);
      for (var i = 0; i < parsed.length; i += 1) {
        expect(parsed[i].duration, records[i].duration);
        expect(parsed[i].displayedFrameCount, records[i].displayedFrameCount);
      }
    });

    test('rejects every truncation and any trailing byte', () {
      final bytes = encodeEncodedChunkIndex(kRecords, manifest);
      for (var length = 0; length < bytes.length; length += 1) {
        _expectFormatError(
          () => parseEncodedChunkIndex(Uint8List.sublistView(bytes, 0, length), manifest),
          FormatErrorCode.indexInvalid,
        );
      }
      final trailing = Uint8List(bytes.length + 1)..setRange(0, bytes.length, bytes);
      _expectFormatError(() => parseEncodedChunkIndex(trailing, manifest), FormatErrorCode.indexInvalid);
    });

    test('rejects magic, size, reserved bytes, and unknown flag bits', () {
      const offsets = [0, 4, 6, 12, 16 + 36, 16 + 40];
      for (final offset in offsets) {
        final bytes = encodeEncodedChunkIndex(kRecords, manifest);
        bytes[offset] = (bytes[offset] ^ 1) & 0xff;
        _expectFormatError(() => parseEncodedChunkIndex(bytes, manifest), FormatErrorCode.indexInvalid);
      }
      final flag = encodeEncodedChunkIndex(kRecords, manifest);
      flag[16 + 32] = 2;
      _expectFormatError(() => parseEncodedChunkIndex(flag, manifest), FormatErrorCode.indexInvalid);
    });

    test('requires independent random-access unit entry and exact displayed coverage', () {
      final entry = encodeEncodedChunkIndex(kRecords, manifest);
      writeUint32LE(entry, 16 + 32, 0);
      _expectFormatError(() => parseEncodedChunkIndex(entry, manifest), FormatErrorCode.indexInvalid);

      final coverage = encodeEncodedChunkIndex(kRecords, manifest);
      writeUint32LE(coverage, 16 + 12, 0);
      _expectFormatError(() => parseEncodedChunkIndex(coverage, manifest), FormatErrorCode.indexInvalid);

      final duration = encodeEncodedChunkIndex(kRecords, manifest);
      writeUint64LE(duration, 16 + 24, BigInt.zero);
      _expectFormatError(() => parseEncodedChunkIndex(duration, manifest), FormatErrorCode.indexInvalid);
    });

    test('rejects zero/over-budget byte lengths and unsafe timestamps', () {
      final zero = encodeEncodedChunkIndex(kRecords, manifest);
      writeUint32LE(zero, 16 + 8, 0);
      _expectFormatError(() => parseEncodedChunkIndex(zero, manifest), FormatErrorCode.indexInvalid);

      _expectFormatError(
        () => parseEncodedChunkIndex(
          encodeEncodedChunkIndex(kRecords, manifest),
          manifest,
          const FormatOptions(budgets: {'maxChunkBytes': 4}),
        ),
        FormatErrorCode.budgetExceeded,
      );

      final unsafe = encodeEncodedChunkIndex(kRecords, manifest);
      writeUint64LE(unsafe, 16 + 16, BigInt.from(maxSafeInteger) + BigInt.one);
      _expectFormatError(() => parseEncodedChunkIndex(unsafe, manifest), FormatErrorCode.integerUnsafe);
    });

    test('cross-checks the canonical manifest chunk spans', () {
      final wrongSpanManifest = _manifestWith(
        rendition: _videoRendition(),
        unit: BodyUnit(
          id: 'body',
          frameCount: 2,
          playback: 'finite',
          ports: const [],
          chunks: [
            UnitChunkSpan(
              rendition: 'video',
              chunkStart: 1,
              chunkCount: 2,
              frameCount: 2,
              sha256: _sha256Zeros,
            ),
          ],
        ),
      );
      _expectFormatError(
        () => parseEncodedChunkIndex(
          encodeEncodedChunkIndex(kRecords, manifest),
          wrongSpanManifest,
        ),
        FormatErrorCode.indexInvalid,
      );
    });

    test('round-trips an index above the former scale', () {
      const recordCount = 100000;
      final bigManifest = _manifestWith(
        rendition: _videoRendition(),
        unit: _bodyUnit(frameCount: recordCount, chunkCount: recordCount),
      );
      final records = List<EncodedChunkRecord>.generate(
        recordCount,
        (index) => EncodedChunkRecord(
          byteOffset: 8000000 + index,
          byteLength: 1,
          presentationTimestamp: index,
          duration: 1,
          randomAccess: index == 0,
          displayedFrameCount: 1,
        ),
      );

      final bytes = encodeEncodedChunkIndex(records, bigManifest);
      final parsed = parseEncodedChunkIndex(bytes, bigManifest);

      expect(bytes.length, greaterThan(4 * 1024 * 1024));
      expect(parsed.length, recordCount);
      expect(parsed.last.presentationTimestamp, recordCount - 1);
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('honors record/index budgets and wraps hostile inputs', () {
      final bytes = encodeEncodedChunkIndex(kRecords, manifest);
      _expectFormatError(
        () => parseEncodedChunkIndex(
          bytes,
          manifest,
          const FormatOptions(budgets: {'maxChunkRecords': 1}),
        ),
        FormatErrorCode.budgetExceeded,
      );
      _expectFormatError(
        () => parseEncodedChunkIndex(
          bytes,
          manifest,
          const FormatOptions(budgets: {'maxIndexBytes': 111}),
        ),
        FormatErrorCode.budgetExceeded,
      );
    });
  });
}
