/// Dart port of `packages/format/test/avc-truncation.test.ts`.
library;

import 'dart:typed_data';

import 'package:aval_format/src/avc/annex_b.dart' show AnnexBNalUnit, splitAnnexBAccessUnit;
import 'package:aval_format/src/avc/index.dart';
import 'package:aval_format/src/avc/parameter_sets.dart' show parsePps, parseSps;
import 'package:aval_format/src/avc/slice_header.dart' show parseSliceHeader;
import 'package:aval_format/src/errors.dart';
import 'package:test/test.dart';

import 'avc_fixture.dart';

void main() {
  group('exhaustive AVC syntax truncation boundaries', () {
    test('rejects every physical byte truncation of AUD, SPS, PPS, and IDR NALs', () {
      final components = <String, Uint8List>{
        'aud': makeAud(0),
        'sps': makeSps(const SpsFixtureOptions(compatibility: 0xe0, bt709Limited: true)),
        'pps': makePps(),
        'idr': makeSlice(const SliceFixtureOptions(idr: true, frameNum: 0, sliceType: 'I')),
      };

      for (final target in components.keys) {
        final bytes = components[target]!;
        for (var byteLength = 0; byteLength < bytes.lengthInBytes; byteLength += 1) {
          final truncated = bytes.sublist(0, byteLength);
          _expectStableProfileInvalid(
            () => inspectAvcAnnexBRendition(
              _oneFrameInput(
                aud: target == 'aud' ? truncated : components['aud']!,
                sps: target == 'sps' ? truncated : components['sps']!,
                pps: target == 'pps' ? truncated : components['pps']!,
                idr: target == 'idr' ? truncated : components['idr']!,
              ).toInspectionInput(),
            ),
            '$target byte $byteLength',
          );
        }
      }
    });

    test('rejects SPS syntax truncated at every bit before its real trailing bit', () {
      final original = _onlyNal(
        makeSps(const SpsFixtureOptions(compatibility: 0xe0, bt709Limited: true)),
        'original.sps',
      );
      final stopBit = _trailingStopBitOffset(original.rbsp);

      for (var bitOffset = 0; bitOffset < stopBit; bitOffset += 1) {
        final candidate = _withRbsp(original, _truncateRbspAt(original.rbsp, bitOffset));
        _expectStableProfileInvalid(
          () => parseSps(candidate, 'sps[$bitOffset]'),
          'SPS bit $bitOffset',
        );
      }

      expect(() => parseSps(original, 'original.sps'), returnsNormally);
    });

    test('rejects PPS syntax truncated at every bit before its real trailing bit', () {
      final original = _onlyNal(makePps(), 'original.pps');
      final stopBit = _trailingStopBitOffset(original.rbsp);

      for (var bitOffset = 0; bitOffset < stopBit; bitOffset += 1) {
        final candidate = _withRbsp(original, _truncateRbspAt(original.rbsp, bitOffset));
        _expectStableProfileInvalid(
          () => parsePps(candidate, 'pps[$bitOffset]', 'fixed-qp26-v0'),
          'PPS bit $bitOffset',
        );
      }

      expect(
        () => parsePps(original, 'original.pps', 'fixed-qp26-v0'),
        returnsNormally,
      );
    });

    final sliceCases = <(String, int, int, Uint8List)>[
      (
        'IDR I',
        0x65,
        16,
        makeSlice(const SliceFixtureOptions(idr: true, frameNum: 0, sliceType: 'I')),
      ),
      (
        'non-IDR P',
        0x61,
        14,
        makeSlice(const SliceFixtureOptions(idr: false, frameNum: 1, sliceType: 'P')),
      ),
    ];
    for (final entry in sliceCases) {
      final label = entry.$1;
      final header = entry.$2;
      final headerBits = entry.$3;
      final bytes = entry.$4;
      test(
        'rejects every bit truncation inside the $label slice header and accepts its exact data boundary',
        () {
          final sps = parseSps(
            _onlyNal(
              makeSps(const SpsFixtureOptions(compatibility: 0xe0, bt709Limited: true)),
              'parameterSets.sps',
            ),
            'parameterSets.sps',
          );
          final pps = parsePps(
            _onlyNal(makePps(), 'parameterSets.pps'),
            'parameterSets.pps',
            'fixed-qp26-v0',
          );
          final original = _onlyNal(bytes, 'original.$label');

          for (var bitOffset = 0; bitOffset < headerBits; bitOffset += 1) {
            final candidate = _withRbsp(original, _truncateRbspAt(original.rbsp, bitOffset));
            _expectStableProfileInvalid(
              () => parseSliceHeader(candidate, pps, sps, 16, 'slice'),
              '$label bit $bitOffset',
            );
          }

          final firstCompleteHeader = _onlyNal(
            nal(
              header,
              _terminateRbspAt(original.rbsp, headerBits),
              original.prefixLength,
            ),
            'slice.completeHeader',
          );
          expect(
            () => parseSliceHeader(firstCompleteHeader, pps, sps, 16, 'slice'),
            returnsNormally,
          );
        },
      );
    }

    test('keeps Annex B prefix, NAL-header, and escaped-RBSP boundary errors stable', () {
      final vectors = <Uint8List>[
        Uint8List.fromList([0]),
        Uint8List.fromList([0, 0]),
        Uint8List.fromList([0, 0, 0]),
        Uint8List.fromList([0, 0, 0, 1]),
        Uint8List.fromList([0, 0, 0, 1, 0x67]),
        Uint8List.fromList([0, 0, 0, 1, 0x67, 0, 0]),
        Uint8List.fromList([0, 0, 0, 1, 0x67, 0, 0, 3]),
        Uint8List.fromList([0, 0, 0, 1, 0x67, 0, 0, 3, 4]),
      ];

      for (var index = 0; index < vectors.length; index += 1) {
        final bytes = vectors[index];
        _expectStableProfileInvalid(
          () => splitAnnexBAccessUnit(bytes, 'annexB[$index]'),
          'Annex B vector $index',
        );
      }
    });
  });
}

MutableInspectionInput _oneFrameInput({
  required Uint8List aud,
  required Uint8List sps,
  required Uint8List pps,
  required Uint8List idr,
}) {
  return validInspectionInput(
    units: [
      MutableUnit(
        id: 'idle',
        accessUnits: [
          MutableAccessUnit.from(
            makeAccessUnit(
              idr: true,
              frameNum: 0,
              aud: aud,
              sps: sps,
              pps: pps,
              slices: [idr],
            ),
          ),
        ],
      ),
    ],
  );
}

AnnexBNalUnit _onlyNal(Uint8List bytes, String path) {
  final units = splitAnnexBAccessUnit(bytes, path, 1);
  expect(units, hasLength(1));
  return units[0];
}

int _trailingStopBitOffset(Uint8List rbsp) {
  for (var bitOffset = rbsp.length * 8 - 1; bitOffset >= 0; bitOffset -= 1) {
    if (_readBit(rbsp, bitOffset) == 1) {
      return bitOffset;
    }
  }
  throw StateError('test fixture has no RBSP stop bit');
}

Uint8List _truncateRbspAt(Uint8List rbsp, int bitOffset) {
  final output = Uint8List((bitOffset / 8).ceil());
  for (var bit = 0; bit < bitOffset; bit += 1) {
    _writeBit(output, bit, _readBit(rbsp, bit));
  }
  return output;
}

Uint8List _terminateRbspAt(Uint8List rbsp, int bitOffset) {
  final output = Uint8List(((bitOffset + 1) / 8).ceil());
  for (var bit = 0; bit < bitOffset; bit += 1) {
    _writeBit(output, bit, _readBit(rbsp, bit));
  }
  _writeBit(output, bitOffset, 1);
  return output;
}

AnnexBNalUnit _withRbsp(AnnexBNalUnit original, Uint8List rbsp) {
  return AnnexBNalUnit(
    type: original.type,
    referenceIdc: original.referenceIdc,
    offset: original.offset,
    prefixLength: original.prefixLength,
    payload: Uint8List.fromList(original.payload),
    rbsp: rbsp,
  );
}

int _readBit(Uint8List bytes, int bitOffset) {
  final byteIndex = bitOffset ~/ 8;
  if (byteIndex >= bytes.length) {
    throw StateError('test bit read exceeds the fixture');
  }
  return (bytes[byteIndex] >> (7 - (bitOffset % 8))) & 1;
}

void _writeBit(Uint8List bytes, int bitOffset, int value) {
  if (value == 0) return;
  final byteIndex = bitOffset ~/ 8;
  bytes[byteIndex] = bytes[byteIndex] | (1 << (7 - (bitOffset % 8)));
}

class _ErrorOutcome {
  const _ErrorOutcome({
    required this.code,
    required this.message,
    this.path,
    this.offset,
  });

  final FormatErrorCode code;
  final String message;
  final String? path;
  final int? offset;

  @override
  bool operator ==(Object other) =>
      other is _ErrorOutcome &&
      other.code == code &&
      other.message == message &&
      other.path == path &&
      other.offset == offset;

  @override
  int get hashCode => Object.hash(code, message, path, offset);

  @override
  String toString() =>
      '_ErrorOutcome(code: $code, message: $message, path: $path, offset: $offset)';
}

_ErrorOutcome _captureProfileInvalid(void Function() callback, String label) {
  try {
    callback();
  } on FormatError catch (error) {
    return _ErrorOutcome(
      code: error.code,
      message: error.message,
      path: error.path,
      offset: error.offset,
    );
  }
  fail('$label unexpectedly passed AVC inspection');
}

void _expectStableProfileInvalid(void Function() callback, String label) {
  final first = _captureProfileInvalid(callback, label);
  final second = _captureProfileInvalid(callback, label);
  expect(second, equals(first), reason: label);
  expect(first.code, FormatErrorCode.profileInvalid, reason: label);
  expect(first.path, isNotNull, reason: label);
  final offset = first.offset;
  if (offset != null) {
    expect(offset, greaterThanOrEqualTo(0), reason: label);
  }
}
