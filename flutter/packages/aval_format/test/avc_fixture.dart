/// Bitstream fixture builders for the AVC test suite (SPS/PPS/slice/AUD Annex
/// B construction), plus mutable inspection-input builders since the
/// production `AvcConstrainedBaselineProfile`/`AvcUnitInput`/
/// `AvcAccessUnitInput` types (`lib/src/avc/types.dart`) are immutable.
///
/// Dart port of `packages/format/test/avc-fixture.ts`. Not a test itself —
/// imported as a plain helper library by the other `avc_*_test.dart` files.
library;

import 'dart:typed_data';

import 'package:aval_format/src/avc/index.dart';
import 'package:aval_format/src/model.dart' show Rect;

class _BitWriter {
  final List<int> _bits = [];

  _BitWriter bit(bool value) {
    _bits.add(value ? 1 : 0);
    return this;
  }

  _BitWriter bits(int value, int width) {
    for (var shift = width - 1; shift >= 0; shift -= 1) {
      bit(((value >> shift) & 1) == 1);
    }
    return this;
  }

  _BitWriter ue(int value) {
    final code = value + 1;
    final width = code.bitLength;
    for (var index = 1; index < width; index += 1) {
      bit(false);
    }
    return bits(code, width);
  }

  _BitWriter se(int value) => ue(value <= 0 ? -2 * value : 2 * value - 1);

  _BitWriter trailing() {
    bit(true);
    while (_bits.length % 8 != 0) {
      bit(false);
    }
    return this;
  }

  Uint8List toBytes() {
    if (_bits.length % 8 != 0) {
      throw StateError('fixture bits must be byte-aligned');
    }
    final bytes = Uint8List(_bits.length ~/ 8);
    for (var index = 0; index < _bits.length; index += 1) {
      if (_bits[index] == 1) {
        final byteIndex = index ~/ 8;
        bytes[byteIndex] = bytes[byteIndex] | (1 << (7 - (index % 8)));
      }
    }
    return bytes;
  }
}

class HrdFixtureOptions {
  const HrdFixtureOptions({
    required this.bitRateValueMinus1,
    required this.cpbSizeValueMinus1,
    this.bitRateScale,
    this.cpbSizeScale,
  });

  final int bitRateValueMinus1;
  final int cpbSizeValueMinus1;
  final int? bitRateScale;
  final int? cpbSizeScale;
}

class SpsFixtureOptions {
  const SpsFixtureOptions({
    this.profileIdc,
    this.compatibility,
    this.levelIdc,
    this.spsId,
    this.picOrderCountType,
    this.maxNumRefFrames,
    this.widthInMacroblocks,
    this.heightInMacroblocks,
    this.crop,
    this.numUnitsInTick,
    this.timeScale,
    this.fixedFrameRate,
    this.maxNumReorderFrames,
    this.maxDecFrameBuffering,
    this.includeVui,
    this.includeBitstreamRestriction,
    this.bt709Limited,
    this.sampleAspectRatio,
    this.hrd,
  });

  final int? profileIdc;
  final int? compatibility;
  final int? levelIdc;
  final int? spsId;

  /// `0 | 1 | 2`.
  final int? picOrderCountType;
  final int? maxNumRefFrames;
  final int? widthInMacroblocks;
  final int? heightInMacroblocks;

  /// `[left, right, top, bottom]`.
  final List<int>? crop;
  final int? numUnitsInTick;
  final int? timeScale;
  final bool? fixedFrameRate;
  final int? maxNumReorderFrames;
  final int? maxDecFrameBuffering;
  final bool? includeVui;
  final bool? includeBitstreamRestriction;
  final bool? bt709Limited;

  /// `[width, height]`.
  final List<int>? sampleAspectRatio;
  final HrdFixtureOptions? hrd;

  SpsFixtureOptions copyWith({
    int? profileIdc,
    int? compatibility,
    int? levelIdc,
    int? spsId,
    int? picOrderCountType,
    int? maxNumRefFrames,
    int? widthInMacroblocks,
    int? heightInMacroblocks,
    List<int>? crop,
    int? numUnitsInTick,
    int? timeScale,
    bool? fixedFrameRate,
    int? maxNumReorderFrames,
    int? maxDecFrameBuffering,
    bool? includeVui,
    bool? includeBitstreamRestriction,
    bool? bt709Limited,
    List<int>? sampleAspectRatio,
    HrdFixtureOptions? hrd,
  }) {
    return SpsFixtureOptions(
      profileIdc: profileIdc ?? this.profileIdc,
      compatibility: compatibility ?? this.compatibility,
      levelIdc: levelIdc ?? this.levelIdc,
      spsId: spsId ?? this.spsId,
      picOrderCountType: picOrderCountType ?? this.picOrderCountType,
      maxNumRefFrames: maxNumRefFrames ?? this.maxNumRefFrames,
      widthInMacroblocks: widthInMacroblocks ?? this.widthInMacroblocks,
      heightInMacroblocks: heightInMacroblocks ?? this.heightInMacroblocks,
      crop: crop ?? this.crop,
      numUnitsInTick: numUnitsInTick ?? this.numUnitsInTick,
      timeScale: timeScale ?? this.timeScale,
      fixedFrameRate: fixedFrameRate ?? this.fixedFrameRate,
      maxNumReorderFrames: maxNumReorderFrames ?? this.maxNumReorderFrames,
      maxDecFrameBuffering: maxDecFrameBuffering ?? this.maxDecFrameBuffering,
      includeVui: includeVui ?? this.includeVui,
      includeBitstreamRestriction:
          includeBitstreamRestriction ?? this.includeBitstreamRestriction,
      bt709Limited: bt709Limited ?? this.bt709Limited,
      sampleAspectRatio: sampleAspectRatio ?? this.sampleAspectRatio,
      hrd: hrd ?? this.hrd,
    );
  }
}

Uint8List makeSps([SpsFixtureOptions options = const SpsFixtureOptions()]) {
  final writer = _BitWriter();
  writer
      .bits(options.profileIdc ?? 66, 8)
      .bits(options.compatibility ?? 0xc0, 8)
      .bits(options.levelIdc ?? 32, 8)
      .ue(options.spsId ?? 0)
      .ue(0);
  final pocType = options.picOrderCountType ?? 2;
  writer.ue(pocType);
  if (pocType == 0) {
    writer.ue(0);
  } else if (pocType == 1) {
    writer.bit(true).se(0).se(0).ue(1).se(2);
  }
  writer
      .ue(options.maxNumRefFrames ?? 1)
      .bit(false)
      .ue((options.widthInMacroblocks ?? 4) - 1)
      .ue((options.heightInMacroblocks ?? 4) - 1)
      .bit(true)
      .bit(true);
  final crop = options.crop;
  writer.bit(crop != null);
  if (crop != null) {
    writer.ue(crop[0]).ue(crop[1]).ue(crop[2]).ue(crop[3]);
  }
  writer.bit(options.includeVui != false);
  if (options.includeVui != false) {
    final sampleAspectRatio = options.sampleAspectRatio;
    writer.bit(sampleAspectRatio != null);
    if (sampleAspectRatio != null) {
      writer
          .bits(255, 8)
          .bits(sampleAspectRatio[0], 16)
          .bits(sampleAspectRatio[1], 16);
    }
    writer.bit(false); // overscan
    writer.bit(options.bt709Limited == true);
    if (options.bt709Limited == true) {
      writer.bits(5, 3).bit(false).bit(true).bits(1, 8).bits(1, 8).bits(1, 8);
    }
    writer.bit(false); // chroma location
    writer
        .bit(true)
        .bits(options.numUnitsInTick ?? 1, 32)
        .bits(options.timeScale ?? 60, 32)
        .bit(options.fixedFrameRate != false);
    writer.bit(options.hrd != null);
    if (options.hrd != null) {
      _writeHrd(writer, options.hrd!);
    }
    writer.bit(false); // vcl hrd
    if (options.hrd != null) {
      writer.bit(true); // low delay HRD
    }
    writer.bit(false); // pic struct
    writer.bit(options.includeBitstreamRestriction != false);
    if (options.includeBitstreamRestriction != false) {
      writer
          .bit(true)
          .ue(2)
          .ue(1)
          .ue(16)
          .ue(16)
          .ue(options.maxNumReorderFrames ?? 0)
          .ue(options.maxDecFrameBuffering ?? 1);
    }
  }
  return nal(0x67, writer.trailing().toBytes(), 4);
}

void _writeHrd(_BitWriter writer, HrdFixtureOptions hrd) {
  writer
      .ue(0)
      .bits(hrd.bitRateScale ?? 0, 4)
      .bits(hrd.cpbSizeScale ?? 0, 4)
      .ue(hrd.bitRateValueMinus1)
      .ue(hrd.cpbSizeValueMinus1)
      .bit(false)
      .bits(23, 5)
      .bits(23, 5)
      .bits(23, 5)
      .bits(0, 5);
}

class PpsFixtureOptions {
  const PpsFixtureOptions({
    this.ppsId,
    this.spsId,
    this.entropyCoding,
    this.sliceGroupsMinus1,
    this.refList0Minus1,
    this.weightedPrediction,
    this.bottomFieldPicOrder,
    this.picInitQpMinus26,
    this.picInitQsMinus26,
    this.chromaQpIndexOffset,
    this.deblockingFilterControl,
    this.constrainedIntraPrediction,
    this.redundantPictures,
    this.extensionBit,
  });

  final int? ppsId;
  final int? spsId;
  final bool? entropyCoding;
  final int? sliceGroupsMinus1;
  final int? refList0Minus1;
  final bool? weightedPrediction;
  final bool? bottomFieldPicOrder;
  final int? picInitQpMinus26;
  final int? picInitQsMinus26;
  final int? chromaQpIndexOffset;
  final bool? deblockingFilterControl;
  final bool? constrainedIntraPrediction;
  final bool? redundantPictures;
  final bool? extensionBit;
}

Uint8List makePps([PpsFixtureOptions options = const PpsFixtureOptions()]) {
  final writer = _BitWriter();
  writer
      .ue(options.ppsId ?? 0)
      .ue(options.spsId ?? 0)
      .bit(options.entropyCoding == true)
      .bit(options.bottomFieldPicOrder == true)
      .ue(options.sliceGroupsMinus1 ?? 0)
      .ue(options.refList0Minus1 ?? 0)
      .ue(0)
      .bit(options.weightedPrediction == true)
      .bits(0, 2)
      .se(options.picInitQpMinus26 ?? 0)
      .se(options.picInitQsMinus26 ?? 0)
      .se(options.chromaQpIndexOffset ?? -2)
      .bit(options.deblockingFilterControl != false)
      .bit(options.constrainedIntraPrediction == true)
      .bit(options.redundantPictures == true);
  if (options.extensionBit == true) {
    writer.bit(true);
  }
  return nal(0x68, writer.trailing().toBytes(), 3);
}

class SliceFixtureOptions {
  const SliceFixtureOptions({
    required this.idr,
    required this.frameNum,
    this.sliceType,
    this.firstMacroblock,
    this.ppsId,
    this.idrPicId,
    this.picOrderCountType,
    this.picOrderCntLsb,
    this.referenceListModification,
    this.adaptiveMarking,
    this.longTermReference,
    this.sliceQpDelta,
  });

  final bool idr;
  final int frameNum;

  /// `"I" | "P" | "B"`.
  final String? sliceType;
  final int? firstMacroblock;
  final int? ppsId;
  final int? idrPicId;

  /// `0 | 1 | 2`.
  final int? picOrderCountType;
  final int? picOrderCntLsb;
  final bool? referenceListModification;
  final bool? adaptiveMarking;
  final bool? longTermReference;
  final int? sliceQpDelta;
}

Uint8List makeSlice(SliceFixtureOptions options) {
  final normalizedType = options.sliceType == 'B'
      ? 1
      : options.sliceType == 'I'
          ? 2
          : 0;
  final writer = _BitWriter();
  writer
      .ue(options.firstMacroblock ?? 0)
      .ue(normalizedType)
      .ue(options.ppsId ?? 0)
      .bits(options.frameNum, 4);
  if (options.idr) {
    writer.ue(options.idrPicId ?? 0);
  }
  if (options.picOrderCountType == 0) {
    writer.bits(options.picOrderCntLsb ?? 0, 4);
  }
  if (normalizedType == 0) {
    writer.bit(false).bit(options.referenceListModification == true);
  }
  if (options.idr) {
    writer.bit(false).bit(options.longTermReference == true);
  } else {
    writer.bit(options.adaptiveMarking == true);
  }
  writer.se(options.sliceQpDelta ?? 0).ue(0).se(0).se(0);
  // One opaque fixture bit stands in for CAVLC slice_data; the inspector does
  // not attempt to entropy-decode macroblocks.
  writer.bit(true).trailing();
  return nal(options.idr ? 0x65 : 0x61, writer.toBytes(), 3);
}

Uint8List makeAud([int primaryPicType = 0]) {
  final writer = _BitWriter();
  writer.bits(primaryPicType, 3);
  return nal(0x09, writer.trailing().toBytes(), 4);
}

AvcAccessUnitInput makeAccessUnit({
  required bool idr,
  required int frameNum,
  bool? key,
  Uint8List? sps,
  Uint8List? pps,
  Uint8List? aud,
  List<Uint8List>? slices,
  int? picOrderCountType,
  int? picOrderCntLsb,
}) {
  final resolvedSlices = slices ??
      [
        makeSlice(
          SliceFixtureOptions(
            idr: idr,
            frameNum: frameNum,
            sliceType: idr ? 'I' : 'P',
            picOrderCountType: picOrderCountType,
            picOrderCntLsb: picOrderCntLsb,
          ),
        ),
      ];
  return AvcAccessUnitInput(
    key: key ?? idr,
    bytes: concat([aud, sps, pps, ...resolvedSlices]),
  );
}

/// Mutable stand-in for a TS `{ numerator, denominator }` object literal.
class MutableFrameRate {
  MutableFrameRate({required this.numerator, required this.denominator});

  int numerator;
  int denominator;
}

/// Mutable stand-in for the TS `MutableInspectionInput["profile"]` object
/// literal; the production `AvcConstrainedBaselineProfile`
/// (`lib/src/avc/types.dart`) is immutable, so tests that mutate profile
/// fields after construction (e.g. `profile.codedWidth = 80`) operate on this
/// type instead and call [toProfile] immediately before inspection.
class MutableProfile {
  MutableProfile({
    required this.codedWidth,
    required this.codedHeight,
    required this.frameRate,
    required this.averageBitrate,
    required this.peakBitrate,
    required this.cpbBufferBits,
    this.requireBt709LimitedRange = true,
    required this.quantizationPolicy,
    this.expectedDecodedStorageRect,
  });

  int codedWidth;
  int codedHeight;
  MutableFrameRate frameRate;
  int averageBitrate;
  int peakBitrate;
  int cpbBufferBits;

  /// Mutable so tests can force the "false" rejection case; the immutable
  /// [AvcConstrainedBaselineProfile] always reads back `true`.
  bool requireBt709LimitedRange;
  String quantizationPolicy;
  Rect? expectedDecodedStorageRect;

  AvcConstrainedBaselineProfile toProfile() => AvcConstrainedBaselineProfile(
        codedWidth: codedWidth,
        codedHeight: codedHeight,
        expectedDecodedStorageRect: expectedDecodedStorageRect,
        frameRate: AvcFrameRate(
          numerator: frameRate.numerator,
          denominator: frameRate.denominator,
        ),
        averageBitrate: averageBitrate,
        peakBitrate: peakBitrate,
        cpbBufferBits: cpbBufferBits,
        quantizationPolicy: quantizationPolicy,
      );
}

/// Mutable stand-in for a TS `{ bytes, key }` access-unit object literal.
class MutableAccessUnit {
  MutableAccessUnit({required this.bytes, required this.key});

  Uint8List bytes;
  bool key;

  AvcAccessUnitInput toAccessUnitInput() =>
      AvcAccessUnitInput(bytes: bytes, key: key);

  static MutableAccessUnit from(AvcAccessUnitInput input) =>
      MutableAccessUnit(bytes: input.bytes, key: input.key);
}

/// Mutable stand-in for a TS `{ id, accessUnits }` unit object literal.
class MutableUnit {
  MutableUnit({required this.id, required this.accessUnits});

  String id;
  List<MutableAccessUnit> accessUnits;

  AvcUnitInput toUnitInput() => AvcUnitInput(
        id: id,
        accessUnits:
            accessUnits.map((unit) => unit.toAccessUnitInput()).toList(),
      );
}

/// Mutable stand-in for the TS `MutableInspectionInput` interface.
class MutableInspectionInput {
  MutableInspectionInput({required this.profile, required this.units});

  MutableProfile profile;
  List<MutableUnit> units;

  AvcRenditionInspectionInput toInspectionInput() =>
      AvcRenditionInspectionInput(
        profile: profile.toProfile(),
        units: units.map((unit) => unit.toUnitInput()).toList(),
      );
}

MutableInspectionInput validInspectionInput({
  SpsFixtureOptions? spsOptions,
  PpsFixtureOptions? ppsOptions,
  String quantizationPolicy = 'fixed-qp26-v0',
  bool requireBt709LimitedRange = true,
  List<MutableUnit>? units,
}) {
  final resolvedSpsOptions = (spsOptions ?? const SpsFixtureOptions()).copyWith(
    compatibility: spsOptions?.compatibility ?? 0xe0,
    bt709Limited: spsOptions?.bt709Limited ?? true,
  );
  final sps = makeSps(resolvedSpsOptions);
  final pps = makePps(ppsOptions ?? const PpsFixtureOptions());

  final resolvedUnits = units ??
      [
        MutableUnit(
          id: 'idle',
          accessUnits: [
            MutableAccessUnit.from(
              makeAccessUnit(
                idr: true,
                frameNum: 0,
                sps: sps,
                pps: pps,
                aud: makeAud(0),
              ),
            ),
            MutableAccessUnit.from(
              makeAccessUnit(idr: false, frameNum: 1, aud: makeAud(1)),
            ),
          ],
        ),
        MutableUnit(
          id: 'hover',
          accessUnits: [
            MutableAccessUnit.from(
              makeAccessUnit(
                idr: true,
                frameNum: 0,
                sps: sps,
                pps: pps,
                aud: makeAud(0),
              ),
            ),
            MutableAccessUnit.from(
              makeAccessUnit(idr: false, frameNum: 1, aud: makeAud(1)),
            ),
          ],
        ),
      ];

  return MutableInspectionInput(
    profile: MutableProfile(
      codedWidth: (spsOptions?.widthInMacroblocks ?? 4) * 16,
      codedHeight: (spsOptions?.heightInMacroblocks ?? 4) * 16,
      frameRate: MutableFrameRate(numerator: 30, denominator: 1),
      averageBitrate: 1000000,
      peakBitrate: 2000000,
      cpbBufferBits: 2000000,
      requireBt709LimitedRange: requireBt709LimitedRange,
      quantizationPolicy: quantizationPolicy,
    ),
    units: resolvedUnits,
  );
}

Uint8List nal(int header, Uint8List rbsp, [int prefixLength = 3]) {
  final escaped = _escapeRbsp(rbsp);
  final output = Uint8List(prefixLength + 1 + escaped.length);
  output[prefixLength - 1] = 1;
  output[prefixLength] = header;
  output.setRange(prefixLength + 1, output.length, escaped);
  return output;
}

Uint8List concat(List<Uint8List?> parts) {
  final present = parts.whereType<Uint8List>().toList();
  final totalLength =
      present.fold<int>(0, (length, part) => length + part.length);
  final result = Uint8List(totalLength);
  var offset = 0;
  for (final part in present) {
    result.setRange(offset, offset + part.length, part);
    offset += part.length;
  }
  return result;
}

Uint8List _escapeRbsp(Uint8List rbsp) {
  final bytes = <int>[];
  var zeroCount = 0;
  for (final byte in rbsp) {
    if (zeroCount == 2 && byte <= 3) {
      bytes.add(3);
      zeroCount = 0;
    }
    bytes.add(byte);
    zeroCount = byte == 0 ? zeroCount + 1 : 0;
  }
  return Uint8List.fromList(bytes);
}
