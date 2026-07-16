/// Dart port of `packages/format/test/avc-encoder-preparation.test.ts`.
library;

import 'dart:typed_data';

import 'package:aval_format/src/avc/annex_b.dart' show AVC_NAL_TYPE_SEI, splitAnnexBAccessUnit;
import 'package:aval_format/src/avc/index.dart';
import 'package:aval_format/src/errors.dart';
import 'package:test/test.dart';

import 'avc_fixture.dart';

void main() {
  group('AVC encoder rendition preparation', () {
    test(
      'removes SEI, normalizes four-byte prefixes, rewrites C0, and strict-reinspects',
      () {
        final first = _rawUnitStream(0xc0);
        final second = _rawUnitStream(0xc0);
        final input = AvcEncoderRenditionPreparationInput(
          profile: _profile(),
          units: [
            AvcEncoderUnitStreamInput(id: 'idle', bytes: first, expectedAccessUnitCount: 2),
            AvcEncoderUnitStreamInput(id: 'hover', bytes: second, expectedAccessUnitCount: 2),
          ],
        );

        final prepared = prepareAvcEncoderRendition(input);
        first.fillRange(0, first.length, 0);
        second.fillRange(0, second.length, 0);

        expect(prepared.inspection.parameterSet.constraintSet2, isTrue);
        expect(prepared.canonicalizations, hasLength(2));
        expect(prepared.canonicalizations[0].unitId, 'idle');
        expect(prepared.canonicalizations[0].constraintSet2Canonicalized, isTrue);
        expect(prepared.canonicalizations[1].unitId, 'hover');
        expect(prepared.canonicalizations[1].constraintSet2Canonicalized, isTrue);
        expect(prepared.units.map((unit) => unit.id).toList(), ['idle', 'hover']);
        expect(
          prepared.units[0].accessUnits.map((unit) => unit.key).toList(),
          [true, false],
        );
        for (final unit in prepared.units) {
          for (var frameIndex = 0; frameIndex < unit.accessUnits.length; frameIndex += 1) {
            final accessUnit = unit.accessUnits[frameIndex];
            final nals = splitAnnexBAccessUnit(accessUnit.bytes, 'prepared');
            expect(nals.every((entry) => entry.prefixLength == 4), isTrue);
            expect(nals.any((entry) => entry.type == AVC_NAL_TYPE_SEI), isFalse);
            expect(
              nals.map((entry) => entry.type).toList(),
              frameIndex == 0 ? [9, 7, 8, 5] : [9, 1],
            );
          }
        }
        expect(
          () => inspectAvcAnnexBRendition(
            AvcRenditionInspectionInput(profile: _profile(), units: prepared.units),
          ),
          returnsNormally,
        );
      },
    );

    test('is byte-stable for an already-E0 candidate apart from canonical framing/SEI', () {
      final prepared = prepareAvcEncoderRendition(
        AvcEncoderRenditionPreparationInput(
          profile: _profile(),
          units: [
            AvcEncoderUnitStreamInput(
              id: 'idle',
              bytes: _rawUnitStream(0xe0),
              expectedAccessUnitCount: 2,
            ),
          ],
        ),
      );
      expect(prepared.inspection.parameterSet.constraintSet2, isTrue);
      expect(prepared.canonicalizations, hasLength(1));
      expect(prepared.canonicalizations[0].unitId, 'idle');
      expect(prepared.canonicalizations[0].constraintSet2Canonicalized, isFalse);
    });

    test('rejects every encoder-only NAL type except zero-reference SEI', () {
      final encoderOnlyNals = <Uint8List>[
        nal(0x0c, Uint8List.fromList([0x80])),
        nal(0x26, Uint8List.fromList([0x80])),
      ];
      for (final encoderOnlyNal in encoderOnlyNals) {
        final raw = concat([
          makeAud(0),
          makeSps(const SpsFixtureOptions(compatibility: 0xc0, bt709Limited: true)),
          makePps(),
          encoderOnlyNal,
          makeAccessUnit(idr: true, frameNum: 0).bytes,
        ]);
        _expectProfileError(
          () => prepareAvcEncoderRendition(
            AvcEncoderRenditionPreparationInput(
              profile: _profile(),
              units: [
                AvcEncoderUnitStreamInput(id: 'idle', bytes: raw, expectedAccessUnitCount: 1),
              ],
            ),
          ),
        );
      }
    });

    test('rejects missing/empty AUD groups and expected-count mismatches', () {
      final noAud = concat([
        makeSps(const SpsFixtureOptions(compatibility: 0xc0, bt709Limited: true)),
        makePps(),
        makeAccessUnit(idr: true, frameNum: 0).bytes,
      ]);
      final emptyGroup = concat([
        makeAud(0),
        nal(0x06, Uint8List.fromList([0x80])),
        makeAud(0),
        makeSps(const SpsFixtureOptions(compatibility: 0xc0, bt709Limited: true)),
        makePps(),
        makeAccessUnit(idr: true, frameNum: 0).bytes,
      ]);
      final cases = <(Uint8List, int)>[
        (noAud, 1),
        (emptyGroup, 2),
        (_rawUnitStream(0xc0), 3),
      ];
      for (final entry in cases) {
        _expectProfileError(
          () => prepareAvcEncoderRendition(
            AvcEncoderRenditionPreparationInput(
              profile: _profile(),
              units: [
                AvcEncoderUnitStreamInput(
                  id: 'idle',
                  bytes: entry.$1,
                  expectedAccessUnitCount: entry.$2,
                ),
              ],
            ),
          ),
        );
      }
    });

    test('candidate-inspects before rewriting and therefore rejects other profile faults', () {
      final raw = _rawUnitStream(0xc0, fixedFrameRate: false);
      _expectProfileError(
        () => prepareAvcEncoderRendition(
          AvcEncoderRenditionPreparationInput(
            profile: _profile(),
            units: [
              AvcEncoderUnitStreamInput(id: 'idle', bytes: raw, expectedAccessUnitCount: 2),
            ],
          ),
        ),
      );
    });

    test(
      'derives its raw NAL budget from authored frame count',
      () {
        const frameCount = 21845;
        final prepared = prepareAvcEncoderRendition(
          AvcEncoderRenditionPreparationInput(
            profile: _profile(),
            units: [
              AvcEncoderUnitStreamInput(
                id: 'idle',
                bytes: _rawLongUnitStream(frameCount),
                expectedAccessUnitCount: frameCount,
              ),
            ],
          ),
        );

        expect(prepared.units[0].accessUnits, hasLength(frameCount));
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test('prepares bounded-v1 encoder output and rejects an out-of-range final QP', () {
      final bounded = const AvcConstrainedBaselineProfile(
        codedWidth: 64,
        codedHeight: 64,
        frameRate: AvcFrameRate(numerator: 30, denominator: 1),
        averageBitrate: 1000000,
        peakBitrate: 2000000,
        cpbBufferBits: 2000000,
        quantizationPolicy: 'bounded-qp-v1',
      );
      expect(
        () => prepareAvcEncoderRendition(
          AvcEncoderRenditionPreparationInput(
            profile: bounded,
            units: [
              AvcEncoderUnitStreamInput(
                id: 'idle',
                bytes: _rawUnitStream(
                  0xc0,
                  picInitQpMinus26: 10,
                  sliceQpDeltas: const [-36, 15],
                ),
                expectedAccessUnitCount: 2,
              ),
            ],
          ),
        ),
        returnsNormally,
      );

      _expectProfileError(
        () => prepareAvcEncoderRendition(
          AvcEncoderRenditionPreparationInput(
            profile: bounded,
            units: [
              AvcEncoderUnitStreamInput(
                id: 'idle',
                bytes: _rawUnitStream(
                  0xc0,
                  picInitQpMinus26: 25,
                  sliceQpDeltas: const [1, 0],
                ),
                expectedAccessUnitCount: 2,
              ),
            ],
          ),
        ),
      );
    });
  });
}

Uint8List _rawUnitStream(
  int compatibility, {
  bool? fixedFrameRate,
  int? picInitQpMinus26,
  List<int>? sliceQpDeltas,
}) {
  final sei = nal(0x06, Uint8List.fromList([0x05, 0x01, 0x80]), 3);
  return concat([
    makeAccessUnit(
      idr: true,
      frameNum: 0,
      aud: makeAud(0),
      sps: makeSps(
        SpsFixtureOptions(
          compatibility: compatibility,
          bt709Limited: true,
          fixedFrameRate: fixedFrameRate,
        ),
      ),
      pps: makePps(PpsFixtureOptions(picInitQpMinus26: picInitQpMinus26)),
      // In normal FFmpeg output SEI follows PPS and precedes the IDR.
      slices: [
        sei,
        makeSlice(
          SliceFixtureOptions(
            idr: true,
            frameNum: 0,
            sliceType: 'I',
            sliceQpDelta: sliceQpDeltas != null ? sliceQpDeltas[0] : 0,
          ),
        ),
      ],
    ).bytes,
    makeAccessUnit(
      idr: false,
      frameNum: 1,
      aud: makeAud(1),
      slices: [
        sei,
        makeSlice(
          SliceFixtureOptions(
            idr: false,
            frameNum: 1,
            sliceType: 'P',
            sliceQpDelta: sliceQpDeltas != null ? sliceQpDeltas[1] : 0,
          ),
        ),
      ],
    ).bytes,
  ]);
}

Uint8List _rawLongUnitStream(int frameCount) {
  final sei = nal(0x06, Uint8List.fromList([0x05, 0x01, 0x80]), 3);
  final parts = <Uint8List>[
    makeAccessUnit(
      idr: true,
      frameNum: 0,
      aud: makeAud(0),
      sps: makeSps(const SpsFixtureOptions(compatibility: 0xc0, bt709Limited: true)),
      pps: makePps(),
      slices: [sei, makeAccessUnit(idr: true, frameNum: 0).bytes],
    ).bytes,
  ];
  for (var frameIndex = 1; frameIndex < frameCount; frameIndex += 1) {
    final frameNum = frameIndex % 16;
    parts.add(
      makeAccessUnit(
        idr: false,
        frameNum: frameNum,
        aud: makeAud(1),
        slices: [sei, makeAccessUnit(idr: false, frameNum: frameNum).bytes],
      ).bytes,
    );
  }
  return concat(parts);
}

AvcConstrainedBaselineProfile _profile() => const AvcConstrainedBaselineProfile(
      codedWidth: 64,
      codedHeight: 64,
      frameRate: AvcFrameRate(numerator: 30, denominator: 1),
      averageBitrate: 1000000,
      peakBitrate: 2000000,
      cpbBufferBits: 2000000,
      quantizationPolicy: 'fixed-qp26-v0',
    );

void _expectProfileError(void Function() callback) {
  expect(callback, throwsA(isA<FormatError>()));
  try {
    callback();
    fail('expected a FormatError');
  } on FormatError catch (error) {
    expect(error.code, FormatErrorCode.profileInvalid);
  }
}
