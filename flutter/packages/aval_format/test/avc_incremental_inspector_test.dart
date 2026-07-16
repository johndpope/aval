/// Dart port of `packages/format/test/avc-incremental-inspector.test.ts`.
library;

import 'dart:typed_data';

import 'package:aval_format/src/avc/index.dart';
import 'package:aval_format/src/errors.dart';
import 'package:test/test.dart';

import 'avc_fixture.dart';

const SpsFixtureOptions _strictSpsOptions =
    SpsFixtureOptions(compatibility: 0xe0, bt709Limited: true);

void main() {
  group('incremental strict AVC inspector', () {
    test('preserves scalar syntax state across calls without retaining input bytes', () {
      final inspector = AvcIncrementalInspector(_strictProfile());
      final stableSps = _strictSps();
      final first = _sample(
        unitInstance: 0,
        unitFrame: 0,
        unitFrameCount: 2,
        bytes: _keyBytes(stableSps),
      );

      final key = inspector.inspect(first);
      first.bytes.fillRange(0, first.bytes.length, 0);
      final delta = inspector.inspect(
        _sample(
          unitInstance: 0,
          unitFrame: 1,
          unitFrameCount: 2,
          bytes: _deltaBytes(1),
          key: false,
        ),
      );
      // A fresh identical SPS must still match after the original caller
      // buffer was destroyed; retaining the original view would make this
      // fail.
      expect(
        () => inspector.inspect(
          _sample(
            unitInstance: 1,
            unitFrame: 0,
            unitFrameCount: 1,
            bytes: _keyBytes(stableSps),
          ),
        ),
        returnsNormally,
      );

      expect(key.unitId, 'idle');
      expect(key.unitInstance, 0);
      expect(key.unitFrame, 0);
      expect(key.unitComplete, isFalse);
      expect(key.chunkType, 'key');
      expect(key.accessUnit.idr, isTrue);
      expect(key.accessUnit.sliceType, 'I');
      expect(key.accessUnit.sliceCount, 1);

      expect(delta.unitFrame, 1);
      expect(delta.unitComplete, isTrue);
      expect(delta.chunkType, 'delta');
      expect(delta.accessUnit.idr, isFalse);
      expect(delta.accessUnit.sliceType, 'P');

      expect(inspector.macroblocksPerFrame, 16);
      expect(inspector.parameterSet!.constraintSet2, isTrue);
      expect(inspector.parameterSet!.fixedFrameRate, isTrue);
      expect(inspector.parameterSet!.squareSampleAspect, isTrue);
      expect(inspector.parameterSet!.hrdPresent, isFalse);
    });

    test('accepts contiguous units across arbitrary call/batch boundaries', () {
      final inspector = AvcIncrementalInspector(_strictProfile());
      inspector.inspect(
        _sample(
          unitId: 'idle',
          unitInstance: 4,
          unitFrame: 0,
          unitFrameCount: 2,
          bytes: _keyBytes(_strictSps()),
        ),
      );
      inspector.inspect(
        _sample(
          unitId: 'idle',
          unitInstance: 4,
          unitFrame: 1,
          unitFrameCount: 2,
          bytes: _deltaBytes(1),
          key: false,
        ),
      );

      final repeated = inspector.inspect(
        _sample(
          unitId: 'idle',
          unitInstance: 5,
          unitFrame: 0,
          unitFrameCount: 1,
          bytes: _keyBytes(_strictSps()),
        ),
      );
      expect(repeated.unitComplete, isTrue);
    });

    test('rejects gaps and inconsistent unit occurrence metadata transactionally', () {
      final inspector = AvcIncrementalInspector(_strictProfile());
      inspector.inspect(
        _sample(
          unitInstance: 0,
          unitFrame: 0,
          unitFrameCount: 3,
          bytes: _keyBytes(_strictSps()),
        ),
      );

      _expectProfileError(
        () => inspector.inspect(
          _sample(
            unitInstance: 0,
            unitFrame: 2,
            unitFrameCount: 3,
            bytes: _deltaBytes(2),
            key: false,
          ),
        ),
      );
      _expectProfileError(
        () => inspector.inspect(
          _sample(
            unitId: 'hover',
            unitInstance: 0,
            unitFrame: 1,
            unitFrameCount: 3,
            bytes: _deltaBytes(1),
            key: false,
          ),
        ),
      );

      expect(
        () => inspector.inspect(
          _sample(
            unitInstance: 0,
            unitFrame: 1,
            unitFrameCount: 3,
            bytes: _deltaBytes(1),
            key: false,
          ),
        ),
        returnsNormally,
      );
    });

    test('requires monotonically new unit instances and independent frame-zero starts', () {
      final inspector = AvcIncrementalInspector(_strictProfile());
      inspector.inspect(
        _sample(
          unitInstance: 2,
          unitFrame: 0,
          unitFrameCount: 1,
          bytes: _keyBytes(_strictSps()),
        ),
      );
      _expectProfileError(
        () => inspector.inspect(
          _sample(
            unitInstance: 2,
            unitFrame: 0,
            unitFrameCount: 1,
            bytes: _keyBytes(_strictSps()),
          ),
        ),
      );
      _expectProfileError(
        () => inspector.inspect(
          _sample(
            unitInstance: 3,
            unitFrame: 1,
            unitFrameCount: 2,
            bytes: _deltaBytes(1),
            key: false,
          ),
        ),
      );
    });

    test('resets generation sequencing but preserves rendition parameter identity', () {
      final inspector = AvcIncrementalInspector(_strictProfile());
      inspector.inspect(
        _sample(
          unitInstance: 8,
          unitFrame: 0,
          unitFrameCount: 1,
          bytes: _keyBytes(_strictSps()),
        ),
      );
      inspector.resetUnitSequence();
      expect(
        () => inspector.inspect(
          _sample(
            unitInstance: 0,
            unitFrame: 0,
            unitFrameCount: 1,
            bytes: _keyBytes(_strictSps()),
          ),
        ),
        returnsNormally,
      );

      inspector.resetUnitSequence();
      _expectProfileError(
        () => inspector.inspect(
          _sample(
            unitInstance: 0,
            unitFrame: 0,
            unitFrameCount: 1,
            bytes: _keyBytes(
              makeSps(_strictSpsOptions.copyWith(spsId: 1)),
              makePps(const PpsFixtureOptions(spsId: 1)),
            ),
          ),
        ),
      );
    });

    test('copies the profile instead of retaining a caller-owned object', () {
      final profile = _strictMutableProfile();
      final inspector = AvcIncrementalInspector(profile.toProfile());
      profile.codedWidth = 80;
      profile.frameRate.numerator = 60;

      expect(
        () => inspector.inspect(
          _sample(
            unitInstance: 0,
            unitFrame: 0,
            unitFrameCount: 1,
            bytes: _keyBytes(_strictSps()),
          ),
        ),
        returnsNormally,
      );
    });

    test('rejects noncanonical strict-worker SPS profiles', () {
      final badSps = <Uint8List>[
        makeSps(_strictSpsOptions.copyWith(compatibility: 0xc0)),
        makeSps(_strictSpsOptions.copyWith(crop: const [0, 1, 0, 0])),
        makeSps(_strictSpsOptions.copyWith(fixedFrameRate: false)),
        makeSps(_strictSpsOptions.copyWith(sampleAspectRatio: const [4, 3])),
        makeSps(
          _strictSpsOptions.copyWith(
            hrd: const HrdFixtureOptions(
              bitRateValueMinus1: 10000,
              cpbSizeValueMinus1: 10000,
            ),
          ),
        ),
      ];
      for (final sps in badSps) {
        final inspector = AvcIncrementalInspector(_strictProfile());
        _expectProfileError(
          () => inspector.inspect(
            _sample(
              unitInstance: 0,
              unitFrame: 0,
              unitFrameCount: 1,
              bytes: _keyBytes(sps),
            ),
          ),
        );
      }
    });

    test('requires exact AUD/SPS/PPS/IDR then AUD/non-IDR grammar with one slice', () {
      final malformedFirstFrames = <Uint8List>[
        makeAccessUnit(idr: true, frameNum: 0, sps: _strictSps(), pps: makePps()).bytes,
        makeAccessUnit(
          idr: true,
          frameNum: 0,
          aud: makeAud(0),
          sps: _strictSps(),
          pps: makePps(),
          slices: [
            makeSlice(const SliceFixtureOptions(idr: true, frameNum: 0, sliceType: 'I')),
            makeSlice(
              const SliceFixtureOptions(
                idr: true,
                frameNum: 0,
                sliceType: 'I',
                firstMacroblock: 8,
              ),
            ),
          ],
        ).bytes,
      ];
      for (final bytes in malformedFirstFrames) {
        final inspector = AvcIncrementalInspector(_strictProfile());
        _expectProfileError(
          () => inspector.inspect(
            _sample(unitInstance: 0, unitFrame: 0, unitFrameCount: 1, bytes: bytes),
          ),
        );
      }

      final laterCases = <(bool, Uint8List)>[
        (true, makeSlice(const SliceFixtureOptions(idr: true, frameNum: 0, sliceType: 'I'))),
        (false, makeSlice(const SliceFixtureOptions(idr: false, frameNum: 1, sliceType: 'I'))),
      ];
      for (final entry in laterCases) {
        final laterIdr = entry.$1;
        final laterSlice = entry.$2;
        final inspector = AvcIncrementalInspector(_strictProfile());
        inspector.inspect(
          _sample(
            unitInstance: 0,
            unitFrame: 0,
            unitFrameCount: 2,
            bytes: _keyBytes(_strictSps()),
          ),
        );
        _expectProfileError(
          () => inspector.inspect(
            _sample(
              unitInstance: 0,
              unitFrame: 1,
              unitFrameCount: 2,
              bytes: makeAccessUnit(
                idr: laterIdr,
                frameNum: laterIdr ? 0 : 1,
                aud: makeAud(laterIdr ? 0 : 1),
                sps: laterIdr ? _strictSps() : null,
                pps: laterIdr ? makePps() : null,
                slices: [laterSlice],
              ).bytes,
              key: laterIdr,
            ),
          ),
        );
      }
    });

    test('rejects a worker CPB profile that differs from peak bitrate', () {
      final profile = _strictMutableProfile();
      profile.cpbBufferBits = profile.peakBitrate - 1;
      _expectProfileError(() => AvcIncrementalInspector(profile.toProfile()));
    });

    test('applies bounded-v1 quantization to every incremental worker sample', () {
      final profile = _strictMutableProfile();
      profile.quantizationPolicy = 'bounded-qp-v1';
      final inspector = AvcIncrementalInspector(profile.toProfile());
      inspector.inspect(
        _sample(
          unitInstance: 0,
          unitFrame: 0,
          unitFrameCount: 2,
          bytes: _keyBytes(
            _strictSps(),
            makePps(const PpsFixtureOptions(picInitQpMinus26: 10)),
            -36,
          ),
        ),
      );
      expect(
        () => inspector.inspect(
          _sample(
            unitInstance: 0,
            unitFrame: 1,
            unitFrameCount: 2,
            bytes: _deltaBytes(1, 15),
            key: false,
          ),
        ),
        returnsNormally,
      );

      final overflow = AvcIncrementalInspector(profile.toProfile());
      _expectProfileError(
        () => overflow.inspect(
          _sample(
            unitInstance: 0,
            unitFrame: 0,
            unitFrameCount: 1,
            bytes: _keyBytes(
              _strictSps(),
              makePps(const PpsFixtureOptions(picInitQpMinus26: 25)),
              1,
            ),
          ),
        ),
      );
    });
  });
}

Uint8List _strictSps() => makeSps(_strictSpsOptions);

MutableProfile _strictMutableProfile() => MutableProfile(
      codedWidth: 64,
      codedHeight: 64,
      frameRate: MutableFrameRate(numerator: 30, denominator: 1),
      averageBitrate: 1000000,
      peakBitrate: 2000000,
      cpbBufferBits: 2000000,
      quantizationPolicy: 'fixed-qp26-v0',
    );

AvcConstrainedBaselineProfile _strictProfile() => _strictMutableProfile().toProfile();

Uint8List _keyBytes(Uint8List sps, [Uint8List? pps, int sliceQpDelta = 0]) {
  return makeAccessUnit(
    idr: true,
    frameNum: 0,
    aud: makeAud(0),
    sps: sps,
    pps: pps ?? makePps(),
    slices: [
      makeSlice(
        SliceFixtureOptions(idr: true, frameNum: 0, sliceType: 'I', sliceQpDelta: sliceQpDelta),
      ),
    ],
  ).bytes;
}

Uint8List _deltaBytes(int frameNum, [int sliceQpDelta = 0]) {
  return makeAccessUnit(
    idr: false,
    frameNum: frameNum,
    aud: makeAud(1),
    slices: [
      makeSlice(
        SliceFixtureOptions(
          idr: false,
          frameNum: frameNum,
          sliceType: 'P',
          sliceQpDelta: sliceQpDelta,
        ),
      ),
    ],
  ).bytes;
}

AvcIncrementalAccessUnitInput _sample({
  String unitId = 'idle',
  bool? key,
  required int unitInstance,
  required int unitFrame,
  required int unitFrameCount,
  required Uint8List bytes,
}) {
  return AvcIncrementalAccessUnitInput(
    bytes: bytes,
    key: key ?? (unitFrame == 0),
    unitId: unitId,
    unitInstance: unitInstance,
    unitFrame: unitFrame,
    unitFrameCount: unitFrameCount,
  );
}

void _expectProfileError(void Function() callback) {
  expect(callback, throwsA(isA<FormatError>()));
  try {
    callback();
    fail('expected a FormatError');
  } on FormatError catch (error) {
    expect(error.code, FormatErrorCode.profileInvalid);
  }
}
