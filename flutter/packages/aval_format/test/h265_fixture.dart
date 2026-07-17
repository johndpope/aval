/// Bitstream fixture builders for the HEVC test suite (VPS/SPS/PPS/slice/AUD
/// Annex-B construction) plus inspection-input builders.
///
/// Dart port of `packages/format/test/h265-fixture.ts`. Not a test itself —
/// imported as a plain helper library by the other `h265_*_test.dart` files.
library;

import 'dart:typed_data';

import 'package:aval_format/src/h265/index.dart';

class H265BitWriter {
  final List<int> _bits = [];

  H265BitWriter bit(bool value) {
    _bits.add(value ? 1 : 0);
    return this;
  }

  H265BitWriter bits(int value, int width) {
    for (var shift = width - 1; shift >= 0; shift -= 1) {
      // TS: Math.floor(value / 2 ** shift) % 2.
      bit((value ~/ (1 << shift)) % 2 == 1);
    }
    return this;
  }

  H265BitWriter ue(int value) {
    final code = value + 1;
    final width = code.bitLength; // floor(log2(code)) + 1
    for (var index = 1; index < width; index += 1) {
      bit(false);
    }
    return bits(code, width);
  }

  H265BitWriter se(int value) => ue(value <= 0 ? -2 * value : value * 2 - 1);

  H265BitWriter trailing() {
    bit(true);
    while (_bits.length % 8 != 0) {
      bit(false);
    }
    return this;
  }

  H265BitWriter opaqueByte([int value = 0x55]) => bits(value, 8);

  Uint8List toBytes() {
    if (_bits.length % 8 != 0) {
      throw StateError('fixture bitstream must be byte aligned');
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

class H265PtlFixtureOptions {
  const H265PtlFixtureOptions({
    this.profileSpace,
    this.tier,
    this.profileIdc,
    this.compatibilityProfileIndexes,
    this.constraintBytes,
    this.levelIdc,
  });

  final int? profileSpace;
  final bool? tier;
  final int? profileIdc;
  final List<int>? compatibilityProfileIndexes;
  final List<int>? constraintBytes;
  final int? levelIdc;
}

void _writePtl(
  H265BitWriter writer, [
  H265PtlFixtureOptions options = const H265PtlFixtureOptions(),
]) {
  writer
      .bits(options.profileSpace ?? 0, 2)
      .bit(options.tier == true)
      .bits(options.profileIdc ?? 1, 5);
  final compatible = (options.compatibilityProfileIndexes ?? [1, 2]).toSet();
  for (var index = 0; index < 32; index += 1) {
    writer.bit(compatible.contains(index));
  }
  final constraints = options.constraintBytes ?? [0x90, 0, 0, 0, 0, 0];
  for (var index = 0; index < 6; index += 1) {
    writer.bits(index < constraints.length ? constraints[index] : 0, 8);
  }
  writer.bits(options.levelIdc ?? 30, 8);
}

Uint8List makeH265Vps([
  H265PtlFixtureOptions ptl = const H265PtlFixtureOptions(),
  int id = 0,
]) {
  final writer = H265BitWriter()
      .bits(id, 4)
      .bit(true)
      .bit(true)
      .bits(0, 6)
      .bits(0, 3)
      .bit(true)
      .bits(0xffff, 16);
  _writePtl(writer, ptl);
  writer
      .bit(true)
      .ue(4)
      .ue(2)
      .ue(0)
      .bits(0, 6)
      .ue(0)
      .bit(false)
      .bit(false)
      .trailing();
  return h265Nal(32, writer.toBytes());
}

class H265SpsFixtureOptions {
  const H265SpsFixtureOptions({
    this.ptl,
    this.vpsId,
    this.spsId,
    this.width,
    this.height,
    this.crop,
    this.bitDepthMinus8,
    this.maxReorder,
    this.maxBufferMinus1,
    this.numUnitsInTick,
    this.timeScale,
    this.color,
    this.fullRange,
    this.includeVui,
    this.longTermReferences,
  });

  final H265PtlFixtureOptions? ptl;
  final int? vpsId;
  final int? spsId;
  final int? width;
  final int? height;

  /// `[left, right, top, bottom]`.
  final List<int>? crop;
  final int? bitDepthMinus8;
  final int? maxReorder;
  final int? maxBufferMinus1;
  final int? numUnitsInTick;
  final int? timeScale;

  /// `[primaries, transfer, matrix]`.
  final List<int>? color;
  final bool? fullRange;
  final bool? includeVui;
  final bool? longTermReferences;
}

Uint8List makeH265Sps([
  H265SpsFixtureOptions options = const H265SpsFixtureOptions(),
]) {
  final writer = H265BitWriter()
      .bits(options.vpsId ?? 0, 4)
      .bits(0, 3)
      .bit(true);
  _writePtl(writer, options.ptl ?? const H265PtlFixtureOptions());
  writer
      .ue(options.spsId ?? 0)
      .ue(1)
      .ue(options.width ?? 64)
      .ue(options.height ?? 64);
  final crop = options.crop;
  writer.bit(crop != null);
  if (crop != null) {
    writer.ue(crop[0]).ue(crop[1]).ue(crop[2]).ue(crop[3]);
  }
  writer
      .ue(options.bitDepthMinus8 ?? 0)
      .ue(options.bitDepthMinus8 ?? 0)
      .ue(4)
      .bit(true)
      .ue(options.maxBufferMinus1 ?? 4)
      .ue(options.maxReorder ?? 2)
      .ue(0)
      .ue(0)
      .ue(3)
      .ue(0)
      .ue(3)
      .ue(0)
      .ue(0)
      .bit(false)
      .bit(false)
      .bit(true)
      .bit(false)
      .ue(0)
      .bit(options.longTermReferences == true);
  if (options.longTermReferences == true) writer.ue(0);
  writer
      .bit(true)
      .bit(true)
      .bit(options.includeVui != false);
  if (options.includeVui != false) {
    final color = options.color ?? [1, 1, 1];
    writer
        .bit(true)
        .bits(1, 8)
        .bit(false)
        .bit(true)
        .bits(5, 3)
        .bit(options.fullRange == true)
        .bit(true)
        .bits(color[0], 8)
        .bits(color[1], 8)
        .bits(color[2], 8)
        .bit(false)
        .bit(false)
        .bit(false)
        .bit(false)
        .bit(false)
        .bit(true)
        .bits(options.numUnitsInTick ?? 1, 32)
        .bits(options.timeScale ?? 5, 32)
        .bit(false)
        .bit(false)
        .bit(false);
  }
  writer.bit(false).trailing();
  return h265Nal(33, writer.toBytes());
}

Uint8List makeH265Pps([int spsId = 0, int ppsId = 0]) {
  final writer = H265BitWriter()
      .ue(ppsId)
      .ue(spsId)
      .bit(false)
      .bit(false)
      .bits(0, 3)
      .bit(true)
      .bit(false)
      .ue(0)
      .ue(0)
      .se(0)
      .bit(false)
      .bit(false)
      .bit(false)
      .se(0)
      .se(0)
      .bit(false)
      .bit(false)
      .bit(false)
      .bit(false)
      .bit(false)
      .bit(true)
      .bit(true)
      .bit(true)
      .bit(false)
      .bit(false)
      .se(0)
      .se(0)
      .bit(false)
      .bit(false)
      .ue(0)
      .bit(false)
      .bit(false)
      .trailing();
  return h265Nal(34, writer.toBytes());
}

Uint8List makeH265Aud(int pictureType) {
  return h265Nal(
    35,
    (H265BitWriter().bits(pictureType, 3).trailing()).toBytes(),
  );
}

class H265SliceFixtureOptions {
  const H265SliceFixtureOptions({
    required this.nalType,
    required this.sliceType,
    this.poc,
    this.negativeReferences,
    this.positiveReferences,
    this.noOutputOfPriorPictures,
    this.ppsId,
    this.opaqueBytes,
  });

  final int nalType;

  /// One of `"I"`, `"P"`, `"B"`.
  final String sliceType;
  final int? poc;
  final List<int>? negativeReferences;
  final List<int>? positiveReferences;
  final bool? noOutputOfPriorPictures;
  final int? ppsId;
  final int? opaqueBytes;
}

Uint8List makeH265Slice(H265SliceFixtureOptions options) {
  final writer = H265BitWriter().bit(true);
  if (options.nalType >= 16 && options.nalType <= 21) {
    writer.bit(options.noOutputOfPriorPictures == true);
  }
  writer.ue(options.ppsId ?? 0).ue(
        options.sliceType == 'I'
            ? 2
            : options.sliceType == 'P'
                ? 1
                : 0,
      );
  if (options.nalType != 19 && options.nalType != 20) {
    writer.bits(options.poc ?? 0, 8).bit(false);
    final negative = options.negativeReferences ?? const [];
    final positive = options.positiveReferences ?? const [];
    writer.ue(negative.length).ue(positive.length);
    var previous = 0;
    for (final delta in negative) {
      if (delta >= previous || delta >= 0) {
        throw StateError('negative RPS must decrease');
      }
      writer.ue(previous - delta - 1).bit(true);
      previous = delta;
    }
    previous = 0;
    for (final delta in positive) {
      if (delta <= previous) {
        throw StateError('positive RPS must increase');
      }
      writer.ue(delta - previous - 1).bit(true);
      previous = delta;
    }
    writer.bit(false);
  }
  writer.trailing();
  for (var index = 0; index < (options.opaqueBytes ?? 4); index += 1) {
    writer.opaqueByte(0x55 + (index % 2));
  }
  return h265Nal(options.nalType, writer.toBytes());
}

class H265AccessUnitFixtureOptions {
  const H265AccessUnitFixtureOptions({
    required this.slice,
    this.vps,
    this.sps,
    this.pps,
    this.metadata,
    this.prefixLength,
  });

  final H265SliceFixtureOptions slice;
  final Uint8List? vps;
  final Uint8List? sps;
  final Uint8List? pps;
  final List<Uint8List>? metadata;

  /// `3` or `4`.
  final int? prefixLength;
}

H265AccessUnitInput makeH265AccessUnit(H265AccessUnitFixtureOptions options) {
  final isKey = options.slice.nalType >= 16 && options.slice.nalType <= 21;
  final pictureType = options.slice.sliceType == 'I'
      ? 0
      : options.slice.sliceType == 'P'
          ? 1
          : 2;
  final nals = <Uint8List>[
    makeH265Aud(pictureType),
    if (options.vps != null) options.vps!,
    if (options.sps != null) options.sps!,
    if (options.pps != null) options.pps!,
    ...(options.metadata ?? const []),
    makeH265Slice(options.slice),
  ];
  final bytes = concat(nals);
  if (options.prefixLength == 3) {
    return H265AccessUnitInput(key: isKey, bytes: replaceStartCodes(bytes, 3));
  }
  return H265AccessUnitInput(key: isKey, bytes: bytes);
}

H265UnitInput makeH265Unit([String id = 'idle']) {
  final vps = makeH265Vps();
  final sps = makeH265Sps();
  final pps = makeH265Pps();
  return H265UnitInput(
    id: id,
    accessUnits: [
      makeH265AccessUnit(H265AccessUnitFixtureOptions(
        vps: vps,
        sps: sps,
        pps: pps,
        slice: const H265SliceFixtureOptions(nalType: 20, sliceType: 'I'),
      )),
      makeH265AccessUnit(const H265AccessUnitFixtureOptions(
        slice: H265SliceFixtureOptions(
          nalType: 1,
          sliceType: 'P',
          poc: 4,
          negativeReferences: [-4],
        ),
      )),
      makeH265AccessUnit(const H265AccessUnitFixtureOptions(
        slice: H265SliceFixtureOptions(
          nalType: 1,
          sliceType: 'B',
          poc: 2,
          negativeReferences: [-2],
          positiveReferences: [2],
        ),
      )),
      makeH265AccessUnit(const H265AccessUnitFixtureOptions(
        slice: H265SliceFixtureOptions(
          nalType: 0,
          sliceType: 'B',
          poc: 1,
          negativeReferences: [-1],
          positiveReferences: [1],
        ),
      )),
      makeH265AccessUnit(const H265AccessUnitFixtureOptions(
        slice: H265SliceFixtureOptions(
          nalType: 0,
          sliceType: 'B',
          poc: 3,
          negativeReferences: [-1],
          positiveReferences: [1],
        ),
      )),
      makeH265AccessUnit(const H265AccessUnitFixtureOptions(
        slice: H265SliceFixtureOptions(
          nalType: 1,
          sliceType: 'P',
          poc: 5,
          negativeReferences: [-1],
        ),
      )),
    ],
  );
}

H265RenditionInspectionInput validH265InspectionInput([
  List<H265UnitInput>? units,
]) {
  return H265RenditionInspectionInput(
    profile: const H265MainProfile(
      codedWidth: 64,
      codedHeight: 64,
      frameRate: H265FrameRate(numerator: 5, denominator: 1),
      requireBt709LimitedRange: true,
    ),
    units: units ?? [makeH265Unit()],
  );
}

Uint8List h265Nal(
  int type,
  Uint8List rbsp, [
  int prefixLength = 4,
  int temporalId = 0,
]) {
  final escaped = _escapeRbsp(rbsp);
  final output = Uint8List(prefixLength + 2 + escaped.length);
  output.setAll(0, prefixLength == 4 ? const [0, 0, 0, 1] : const [0, 0, 1]);
  output[prefixLength] = type << 1;
  output[prefixLength + 1] = temporalId + 1;
  output.setAll(prefixLength + 2, escaped);
  return output;
}

Uint8List concat(List<Uint8List> parts) {
  final length = parts.fold<int>(0, (total, part) => total + part.length);
  final output = Uint8List(length);
  var offset = 0;
  for (final part in parts) {
    output.setAll(offset, part);
    offset += part.length;
  }
  return output;
}

Uint8List _escapeRbsp(Uint8List rbsp) {
  final output = <int>[];
  var zeroCount = 0;
  for (final byte in rbsp) {
    if (zeroCount == 2 && byte <= 3) {
      output.add(3);
      zeroCount = 0;
    }
    output.add(byte);
    zeroCount = byte == 0 ? zeroCount + 1 : 0;
  }
  return Uint8List.fromList(output);
}

Uint8List replaceStartCodes(Uint8List bytes, int length) {
  final parts = <Uint8List>[];
  var start = 0;
  for (var index = 0; index + 3 < bytes.length; index += 1) {
    if (bytes[index] == 0 &&
        bytes[index + 1] == 0 &&
        bytes[index + 2] == 0 &&
        bytes[index + 3] == 1) {
      if (index > start) {
        parts.add(Uint8List.sublistView(bytes, start, index));
      }
      parts.add(
        Uint8List.fromList(length == 4 ? const [0, 0, 0, 1] : const [0, 0, 1]),
      );
      start = index + 4;
      index += 3;
    }
  }
  parts.add(Uint8List.sublistView(bytes, start));
  return concat(parts);
}
