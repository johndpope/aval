/// Dart port of `packages/format/test/avc-inspector.test.ts`.
library;

import 'dart:typed_data';

import 'package:aval_format/src/avc/index.dart';
import 'package:aval_format/src/errors.dart';
import 'package:aval_format/src/model.dart' show Rect;
import 'package:test/test.dart';

import 'avc_fixture.dart';

void main() {
  group('AVC Annex B Constrained Baseline inspector', () {
    test('accepts stable independently decodable I/P units', () {
      final inspection = inspectAvcAnnexBRendition(validInspectionInput().toInspectionInput());

      expect(inspection.macroblocksPerFrame, 16);
      expect(inspection.parameterSet.profileIdc, 66);
      expect(inspection.parameterSet.constraintSet2, isTrue);
      expect(inspection.parameterSet.levelIdc, 32);
      expect(inspection.parameterSet.codedWidth, 64);
      expect(inspection.parameterSet.codedHeight, 64);
      expect(inspection.parameterSet.maxNumRefFrames, 1);
      expect(inspection.parameterSet.maxNumReorderFrames, 0);
      expect(inspection.parameterSet.maxDecFrameBuffering, 1);
      expect(inspection.parameterSet.hrdPresent, isFalse);
      expect(inspection.units.map((unit) => unit.id).toList(), ['idle', 'hover']);
      final frames = inspection.units[0].frames;
      expect(frames[0].key, isTrue);
      expect(frames[0].idr, isTrue);
      expect(frames[0].sliceType, 'I');
      expect(frames[0].nalUnitTypes, [9, 7, 8, 5]);
      expect(frames[1].key, isFalse);
      expect(frames[1].idr, isFalse);
      expect(frames[1].sliceType, 'P');
      expect(frames[1].nalUnitTypes, [9, 1]);
    });

    test('accepts a known authored AVC level and derives its codec string', () {
      final inspection = inspectAvcAnnexBRendition(
        validInspectionInput(spsOptions: const SpsFixtureOptions(levelIdc: 40))
            .toInspectionInput(),
      );

      expect(inspection.parameterSet.levelIdc, 40);
      expect(avcCodecForLevel(inspection.parameterSet.levelIdc), 'avc1.42E028');
    });

    test('rejects a pathological aspect ratio that exceeds the level dimension rule', () {
      final input = validInspectionInput(
        spsOptions: const SpsFixtureOptions(
          levelIdc: 62,
          widthInMacroblocks: 1056,
          heightInMacroblocks: 1,
        ),
      );
      input.profile.averageBitrate = 1000000;
      input.profile.peakBitrate = 2000000;
      input.profile.cpbBufferBits = 2000000;

      _expectProfileError(() => inspectAvcAnnexBRendition(input.toInspectionInput()));
    });

    test('requires E0 strictly while the named encoder candidate accepts only C0/E0', () {
      expect(
        inspectAvcAnnexBRendition(validInspectionInput().toInspectionInput())
            .parameterSet
            .constraintSet2,
        isTrue,
      );
      final c0 = validInspectionInput(
        spsOptions: const SpsFixtureOptions(compatibility: 0xc0),
      );
      _expectProfileError(() => inspectAvcAnnexBRendition(c0.toInspectionInput()));
      expect(
        inspectAvcAnnexBEncoderCandidateRendition(c0.toInspectionInput())
            .parameterSet
            .constraintSet2,
        isFalse,
      );
      expect(
        inspectAvcAnnexBEncoderCandidateRendition(
          validInspectionInput(
            spsOptions: const SpsFixtureOptions(compatibility: 0xe0),
          ).toInspectionInput(),
        ).parameterSet.constraintSet2,
        isTrue,
      );
    });

    test('rejects multiple slices even when they partition one picture', () {
      final sps = makeSps(const SpsFixtureOptions(compatibility: 0xe0));
      final pps = makePps();
      final input = validInspectionInput(
        units: [
          MutableUnit(
            id: 'idle',
            accessUnits: [
              MutableAccessUnit.from(
                makeAccessUnit(
                  idr: true,
                  frameNum: 0,
                  sps: sps,
                  pps: pps,
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
                ),
              ),
            ],
          ),
        ],
      );

      _expectProfileError(() => inspectAvcAnnexBRendition(input.toInspectionInput()));
    });

    test('rejects SPS crop and non-BT.709 signalling', () {
      _expectProfileError(
        () => inspectAvcAnnexBRendition(
          validInspectionInput(spsOptions: const SpsFixtureOptions(crop: [1, 2, 3, 4]))
              .toInspectionInput(),
        ),
      );
      _expectProfileError(
        () => inspectAvcAnnexBRendition(
          validInspectionInput(spsOptions: const SpsFixtureOptions(bt709Limited: false))
              .toInspectionInput(),
        ),
      );
    });

    test('accepts only the exact expected decoded-storage SPS crop', () {
      final geometry = deriveAvcRenditionGeometry(
        const AvcRenditionGeometryInput(
          canvasWidth: 61,
          canvasHeight: 59,
          profile: 'avc-annexb-opaque-v0',
          codedWidth: 64,
          codedHeight: 64,
          colorRect: Rect(0, 0, 61, 59),
        ),
      );
      expect(geometry.decodedStorageRect, Rect(0, 0, 62, 60));

      final exact = validInspectionInput(
        spsOptions: const SpsFixtureOptions(crop: [0, 1, 0, 2]),
      );
      exact.profile.expectedDecodedStorageRect = geometry.decodedStorageRect;
      final crop = inspectAvcAnnexBRendition(exact.toInspectionInput()).parameterSet.crop;
      expect(crop.left, 0);
      expect(crop.right, 2);
      expect(crop.top, 0);
      expect(crop.bottom, 4);
      expect(crop.visibleWidth, 62);
      expect(crop.visibleHeight, 60);

      final mismatch = validInspectionInput(
        spsOptions: const SpsFixtureOptions(crop: [0, 1, 0, 2]),
      );
      mismatch.profile.expectedDecodedStorageRect = const Rect(0, 0, 62, 62);
      _expectProfileError(() => inspectAvcAnnexBRendition(mismatch.toInspectionInput()));

      final nonzeroOrigin = validInspectionInput();
      nonzeroOrigin.profile.expectedDecodedStorageRect = const Rect(2, 0, 62, 64);
      _expectProfileError(() => inspectAvcAnnexBRendition(nonzeroOrigin.toInspectionInput()));
    });

    test('rejects NAL HRD declarations', () {
      _expectProfileError(
        () => inspectAvcAnnexBRendition(
          validInspectionInput(
            spsOptions: const SpsFixtureOptions(
              hrd: HrdFixtureOptions(bitRateValueMinus1: 10000, cpbSizeValueMinus1: 100000),
            ),
          ).toInspectionInput(),
        ),
      );
    });

    final spsViolations = <(String, SpsFixtureOptions)>[
      ('wrong profile', const SpsFixtureOptions(profileIdc: 77)),
      ('missing constraints', const SpsFixtureOptions(compatibility: 0x00)),
      ('reserved constraints', const SpsFixtureOptions(compatibility: 0xc1)),
      ('unknown level', const SpsFixtureOptions(levelIdc: 33)),
      ('too many references', const SpsFixtureOptions(maxNumRefFrames: 2)),
      ('reordering', const SpsFixtureOptions(maxNumReorderFrames: 1)),
      ('undersized DPB', const SpsFixtureOptions(maxDecFrameBuffering: 0)),
      ('missing VUI', const SpsFixtureOptions(includeVui: false)),
      ('missing restriction', const SpsFixtureOptions(includeBitstreamRestriction: false)),
    ];
    for (final entry in spsViolations) {
      test('rejects SPS profile violation: ${entry.$1}', () {
        _expectProfileError(
          () => inspectAvcAnnexBRendition(
            validInspectionInput(spsOptions: entry.$2).toInspectionInput(),
          ),
        );
      });
    }

    test('rejects a clear fixed_frame_rate_flag', () {
      _expectProfileError(
        () => inspectAvcAnnexBRendition(
          validInspectionInput(spsOptions: const SpsFixtureOptions(fixedFrameRate: false))
              .toInspectionInput(),
        ),
      );
    });

    test('rejects dimensions, macroblock rate, VUI timing, and packed-alpha colour mismatches', () {
      final dimensions = validInspectionInput();
      dimensions.profile.codedWidth = 80;
      _expectProfileError(() => inspectAvcAnnexBRendition(dimensions.toInspectionInput()));

      final macroblockRate = validInspectionInput(
        spsOptions: const SpsFixtureOptions(widthInMacroblocks: 81, heightInMacroblocks: 64),
      );
      _expectProfileError(() => inspectAvcAnnexBRendition(macroblockRate.toInspectionInput()));

      final perSecond = validInspectionInput(
        spsOptions: const SpsFixtureOptions(
          widthInMacroblocks: 80,
          heightInMacroblocks: 64,
          timeScale: 120,
        ),
      );
      perSecond.profile.frameRate.numerator = 60;
      _expectProfileError(() => inspectAvcAnnexBRendition(perSecond.toInspectionInput()));

      final dpb = validInspectionInput(
        spsOptions: const SpsFixtureOptions(maxDecFrameBuffering: 17),
      );
      _expectProfileError(() => inspectAvcAnnexBRendition(dpb.toInspectionInput()));

      final timing = validInspectionInput(spsOptions: const SpsFixtureOptions(timeScale: 50));
      _expectProfileError(() => inspectAvcAnnexBRendition(timing.toInspectionInput()));

      final color = validInspectionInput(
        spsOptions: const SpsFixtureOptions(bt709Limited: false),
        requireBt709LimitedRange: true,
      );
      _expectProfileError(() => inspectAvcAnnexBRendition(color.toInspectionInput()));
    });

    test('requires the exact CPB rule', () {
      final cpb = validInspectionInput();
      cpb.profile.cpbBufferBits -= 1;
      _expectProfileError(() => inspectAvcAnnexBRendition(cpb.toInspectionInput()));

      // NOTE: the TS source also forces
      // `(color.profile as { requireBt709LimitedRange?: boolean })
      //   .requireBt709LimitedRange = false` and asserts rejection. That is
      // untestable here: `AvcConstrainedBaselineProfile.requireBt709LimitedRange`
      // (lib/src/avc/types.dart, part of the already-ported type surface this
      // task must not modify) is a hardcoded `bool get ... => true`, not a
      // stored field, so no Dart value of this type can ever violate it —
      // the corresponding `cloneAvcProfile` check is unreachable by
      // construction rather than exercised at runtime.
    });

    test('rejects declared and signalled rate/buffer excesses', () {
      final declared = validInspectionInput();
      declared.profile.peakBitrate = 8000001;
      _expectProfileError(() => inspectAvcAnnexBRendition(declared.toInspectionInput()));

      final hrdBitrate = validInspectionInput(
        spsOptions: const SpsFixtureOptions(
          hrd: HrdFixtureOptions(bitRateValueMinus1: 125000, cpbSizeValueMinus1: 1),
        ),
      );
      _expectProfileError(() => inspectAvcAnnexBRendition(hrdBitrate.toInspectionInput()));

      final hrdCpb = validInspectionInput(
        spsOptions: const SpsFixtureOptions(
          hrd: HrdFixtureOptions(bitRateValueMinus1: 1, cpbSizeValueMinus1: 500000),
        ),
      );
      _expectProfileError(() => inspectAvcAnnexBRendition(hrdCpb.toInspectionInput()));

      final aboveDeclaredBitrate = validInspectionInput(
        spsOptions: const SpsFixtureOptions(
          hrd: HrdFixtureOptions(bitRateValueMinus1: 20000, cpbSizeValueMinus1: 1),
        ),
      );
      aboveDeclaredBitrate.profile.peakBitrate = 1000000;
      _expectProfileError(
        () => inspectAvcAnnexBRendition(aboveDeclaredBitrate.toInspectionInput()),
      );

      final aboveConfiguredCpb = validInspectionInput(
        spsOptions: const SpsFixtureOptions(
          hrd: HrdFixtureOptions(bitRateValueMinus1: 1, cpbSizeValueMinus1: 150000),
        ),
      );
      _expectProfileError(() => inspectAvcAnnexBRendition(aboveConfiguredCpb.toInspectionInput()));
    });

    final ppsViolations = <(String, PpsFixtureOptions)>[
      ('CABAC', const PpsFixtureOptions(entropyCoding: true)),
      ('FMO', const PpsFixtureOptions(sliceGroupsMinus1: 1)),
      ('multiple default refs', const PpsFixtureOptions(refList0Minus1: 1)),
      ('weighted prediction', const PpsFixtureOptions(weightedPrediction: true)),
      ('bottom-field picture order', const PpsFixtureOptions(bottomFieldPicOrder: true)),
      ('non-frozen initial QP', const PpsFixtureOptions(picInitQpMinus26: 1)),
      ('non-frozen initial QS', const PpsFixtureOptions(picInitQsMinus26: -1)),
      ('non-frozen chroma QP', const PpsFixtureOptions(chromaQpIndexOffset: 0)),
      ('missing deblocking control', const PpsFixtureOptions(deblockingFilterControl: false)),
      ('constrained intra prediction', const PpsFixtureOptions(constrainedIntraPrediction: true)),
      ('redundant pictures', const PpsFixtureOptions(redundantPictures: true)),
      ('PPS extension', const PpsFixtureOptions(extensionBit: true)),
    ];
    for (final entry in ppsViolations) {
      test('rejects PPS violation: ${entry.$1}', () {
        final sps = makeSps(const SpsFixtureOptions(compatibility: 0xe0));
        final input = validInspectionInput(
          units: [
            MutableUnit(
              id: 'idle',
              accessUnits: [
                MutableAccessUnit.from(
                  makeAccessUnit(
                    idr: true,
                    frameNum: 0,
                    sps: sps,
                    pps: makePps(entry.$2),
                  ),
                ),
              ],
            ),
          ],
        );
        _expectProfileError(() => inspectAvcAnnexBRendition(input.toInspectionInput()));
      });
    }

    test('versions frozen-v0 and bounded-v1 quantization without relaxing PPS identity', () {
      final accepted = _quantizedInput('bounded-qp-v1', 10, const [-36, 15]);
      expect(
        () => inspectAvcAnnexBRendition(accepted.toInspectionInput()),
        returnsNormally,
      );

      final frozenV0 = _quantizedInput('fixed-qp26-v0', 1, const [0]);
      _expectProfileError(() => inspectAvcAnnexBRendition(frozenV0.toInspectionInput()));

      final changed = _quantizedInput('bounded-qp-v1', 10, const [0]);
      final changedSps = makeSps(const SpsFixtureOptions(compatibility: 0xe0, bt709Limited: true));
      changed.units.add(
        MutableUnit(
          id: 'hover',
          accessUnits: [
            MutableAccessUnit.from(
              makeAccessUnit(
                idr: true,
                frameNum: 0,
                aud: makeAud(0),
                sps: changedSps,
                pps: makePps(const PpsFixtureOptions(picInitQpMinus26: 11)),
              ),
            ),
          ],
        ),
      );
      _expectProfileError(() => inspectAvcAnnexBRendition(changed.toInspectionInput()));
    });

    final boundedQpViolations = <(String, int, int)>[
      ('underflow', -26, -1),
      ('overflow', 25, 1),
    ];
    for (final entry in boundedQpViolations) {
      test('rejects bounded-v1 final slice QP ${entry.$1}', () {
        final input = _quantizedInput('bounded-qp-v1', entry.$2, [entry.$3]);
        _expectProfileError(() => inspectAvcAnnexBRendition(input.toInspectionInput()));
      });
    }

    test('rejects B pictures, list reordering, adaptive marking, and long-term IDR', () {
      for (final slice in [
        makeSlice(const SliceFixtureOptions(idr: false, frameNum: 1, sliceType: 'B')),
        makeSlice(
          const SliceFixtureOptions(
            idr: false,
            frameNum: 1,
            sliceType: 'P',
            referenceListModification: true,
          ),
        ),
        makeSlice(
          const SliceFixtureOptions(
            idr: false,
            frameNum: 1,
            sliceType: 'P',
            adaptiveMarking: true,
          ),
        ),
      ]) {
        final input = validInspectionInput();
        input.units[0].accessUnits[1] = MutableAccessUnit.from(
          makeAccessUnit(idr: false, frameNum: 1, slices: [slice]),
        );
        _expectProfileError(() => inspectAvcAnnexBRendition(input.toInspectionInput()));
      }

      final input = validInspectionInput();
      final sps = makeSps(const SpsFixtureOptions(compatibility: 0xe0));
      final pps = makePps();
      input.units[0].accessUnits[0] = MutableAccessUnit.from(
        makeAccessUnit(
          idr: true,
          frameNum: 0,
          sps: sps,
          pps: pps,
          slices: [
            makeSlice(
              const SliceFixtureOptions(
                idr: true,
                frameNum: 0,
                sliceType: 'I',
                longTermReference: true,
              ),
            ),
          ],
        ),
      );
      _expectProfileError(() => inspectAvcAnnexBRendition(input.toInspectionInput()));
    });

    test('rejects false key flags and non-independent unit starts', () {
      final falseNonKey = validInspectionInput();
      falseNonKey.units[0].accessUnits[0].key = false;
      _expectProfileError(() => inspectAvcAnnexBRendition(falseNonKey.toInspectionInput()));

      final falseKey = validInspectionInput();
      falseKey.units[0].accessUnits[1].key = true;
      _expectProfileError(() => inspectAvcAnnexBRendition(falseKey.toInspectionInput()));

      final nonIdrStart = validInspectionInput();
      nonIdrStart.units[1].accessUnits[0] = MutableAccessUnit.from(
        makeAccessUnit(idr: false, frameNum: 1),
      );
      _expectProfileError(() => inspectAvcAnnexBRendition(nonIdrStart.toInspectionInput()));
    });

    test('rejects missing or unstable parameter sets', () {
      final missing = validInspectionInput();
      missing.units[0].accessUnits[0] = MutableAccessUnit.from(
        makeAccessUnit(idr: true, frameNum: 0),
      );
      _expectProfileError(() => inspectAvcAnnexBRendition(missing.toInspectionInput()));

      final changed = validInspectionInput();
      changed.units[1].accessUnits[0] = MutableAccessUnit.from(
        makeAccessUnit(
          idr: true,
          frameNum: 0,
          sps: makeSps(const SpsFixtureOptions(compatibility: 0xe0, spsId: 1)),
          pps: makePps(const PpsFixtureOptions(spsId: 1)),
        ),
      );
      _expectProfileError(() => inspectAvcAnnexBRendition(changed.toInspectionInput()));
    });

    test('rejects multiple pictures and invalid slice partitions in one access unit', () {
      final sps = makeSps(const SpsFixtureOptions(compatibility: 0xe0));
      final pps = makePps();
      final multiplePictures = validInspectionInput(
        units: [
          MutableUnit(
            id: 'idle',
            accessUnits: [
              MutableAccessUnit.from(
                makeAccessUnit(
                  idr: true,
                  frameNum: 0,
                  sps: sps,
                  pps: pps,
                  slices: [
                    makeSlice(const SliceFixtureOptions(idr: true, frameNum: 0, sliceType: 'I')),
                    makeSlice(const SliceFixtureOptions(idr: true, frameNum: 1, sliceType: 'I')),
                  ],
                ),
              ),
            ],
          ),
        ],
      );
      _expectProfileError(() => inspectAvcAnnexBRendition(multiplePictures.toInspectionInput()));

      final badPartition = validInspectionInput(
        units: [
          MutableUnit(
            id: 'idle',
            accessUnits: [
              MutableAccessUnit.from(
                makeAccessUnit(
                  idr: true,
                  frameNum: 0,
                  sps: sps,
                  pps: pps,
                  slices: [
                    makeSlice(
                      const SliceFixtureOptions(
                        idr: true,
                        frameNum: 0,
                        sliceType: 'I',
                        firstMacroblock: 1,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      );
      _expectProfileError(() => inspectAvcAnnexBRendition(badPartition.toInspectionInput()));
    });

    test('rejects frame_num gaps and POC reordering', () {
      final gap = validInspectionInput();
      gap.units[0].accessUnits[1] = MutableAccessUnit.from(
        makeAccessUnit(idr: false, frameNum: 2),
      );
      _expectProfileError(() => inspectAvcAnnexBRendition(gap.toInspectionInput()));

      final sps = makeSps(
        const SpsFixtureOptions(compatibility: 0xe0, picOrderCountType: 0),
      );
      final pps = makePps();
      final reordered = validInspectionInput(
        spsOptions: const SpsFixtureOptions(picOrderCountType: 0),
        units: [
          MutableUnit(
            id: 'idle',
            accessUnits: [
              MutableAccessUnit.from(
                makeAccessUnit(
                  idr: true,
                  frameNum: 0,
                  sps: sps,
                  pps: pps,
                  picOrderCountType: 0,
                  picOrderCntLsb: 0,
                ),
              ),
              MutableAccessUnit.from(
                makeAccessUnit(
                  idr: false,
                  frameNum: 1,
                  picOrderCountType: 0,
                  picOrderCntLsb: 4,
                ),
              ),
              MutableAccessUnit.from(
                makeAccessUnit(
                  idr: false,
                  frameNum: 2,
                  picOrderCountType: 0,
                  picOrderCntLsb: 2,
                ),
              ),
            ],
          ),
        ],
      );
      _expectProfileError(() => inspectAvcAnnexBRendition(reordered.toInspectionInput()));
    });

    test('rejects forbidden NAL types, headers, order, and AUD claims', () {
      final sps = makeSps(const SpsFixtureOptions(compatibility: 0xe0));
      final pps = makePps();
      final idr = makeSlice(const SliceFixtureOptions(idr: true, frameNum: 0, sliceType: 'I'));
      final variants = <Uint8List>[
        concat([nal(0x06, Uint8List.fromList([0x80]), 3), sps, pps, idr]),
        concat([nal(0xe7, Uint8List.fromList([0x80]), 3), pps, idr]),
        concat([nal(0x07, Uint8List.fromList([0x80]), 3), pps, idr]),
        concat([sps, makeAud(0), pps, idr]),
        concat([makeAud(2), sps, pps, idr]),
      ];
      for (final bytes in variants) {
        final input = validInspectionInput();
        input.units[0].accessUnits[0] = MutableAccessUnit(bytes: bytes, key: true);
        _expectProfileError(() => inspectAvcAnnexBRendition(input.toInspectionInput()));
      }
    });

    test('rejects hostile start codes and EBSP escaping', () {
      final hostile = <Uint8List>[
        Uint8List.fromList([1, 2, 3, 4, 5]),
        Uint8List.fromList([9, 0, 0, 1, 0x65, 0x80]),
        Uint8List.fromList([0, 0, 0, 0, 1, 0x65, 0x80]),
        Uint8List.fromList([0, 0, 1, 0x65, 0, 0, 1, 0x61, 0x80]),
        Uint8List.fromList([0, 0, 1, 0x65, 0x80, 0]),
        Uint8List.fromList([0, 0, 1, 0x65, 0, 0, 3, 4, 0x80]),
        Uint8List.fromList([0, 0, 1, 0x65, 0, 0, 2, 0x80]),
      ];
      for (final bytes in hostile) {
        final input = validInspectionInput();
        input.units[0].accessUnits[0] = MutableAccessUnit(bytes: bytes, key: true);
        _expectProfileError(() => inspectAvcAnnexBRendition(input.toInspectionInput()));
      }
    });

    test('rejects truncated Exp-Golomb and bad parameter-set trailing bits', () {
      final pps = makePps();
      final idr = makeSlice(const SliceFixtureOptions(idr: true, frameNum: 0, sliceType: 'I'));
      final badSpsList = <Uint8List>[
        nal(0x67, Uint8List.fromList([66, 0xc0, 32, 0]), 4),
        nal(0x67, Uint8List.fromList([66, 0xc0, 32, 0x80, 0x7f]), 4),
      ];
      for (final badSps in badSpsList) {
        final input = validInspectionInput();
        input.units[0].accessUnits[0] = MutableAccessUnit(
          bytes: concat([badSps, pps, idr]),
          key: true,
        );
        _expectProfileError(() => inspectAvcAnnexBRendition(input.toInspectionInput()));
      }
    });
  });
}

MutableInspectionInput _quantizedInput(
  String quantizationPolicy,
  int picInitQpMinus26,
  List<int> sliceQpDeltas,
) {
  final sps = makeSps(const SpsFixtureOptions(compatibility: 0xe0, bt709Limited: true));
  final pps = makePps(PpsFixtureOptions(picInitQpMinus26: picInitQpMinus26));
  final accessUnits = <MutableAccessUnit>[];
  for (var frameIndex = 0; frameIndex < sliceQpDeltas.length; frameIndex += 1) {
    final isFirst = frameIndex == 0;
    accessUnits.add(
      MutableAccessUnit.from(
        makeAccessUnit(
          idr: isFirst,
          frameNum: frameIndex,
          aud: makeAud(isFirst ? 0 : 1),
          sps: isFirst ? sps : null,
          pps: isFirst ? pps : null,
          slices: [
            makeSlice(
              SliceFixtureOptions(
                idr: isFirst,
                frameNum: frameIndex,
                sliceType: isFirst ? 'I' : 'P',
                sliceQpDelta: sliceQpDeltas[frameIndex],
              ),
            ),
          ],
        ),
      ),
    );
  }
  return validInspectionInput(
    quantizationPolicy: quantizationPolicy,
    units: [MutableUnit(id: 'idle', accessUnits: accessUnits)],
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
