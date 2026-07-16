/// Dart port of `packages/format/test/avc-mutation-fuzz.test.ts`.
///
/// GAPS vs the TS source (documented, not fixable within this package):
/// - The TS test resolves its seed list via `mutationSeeds` from the
///   monorepo-level `tests/mutation/seed-profile.ts` (env-var driven matrix
///   runs, up to 64 seeds). That module lives outside `packages/format` and
///   is a cross-package test-orchestration concern, not part of the AVC
///   subsystem being ported here, so this port hardcodes the single documented
///   fallback seed (`0x5a17_0c5e`) instead of reproducing that harness.
/// - `Object.isFrozen` assertions are dropped; Dart has no runtime-freeze
///   equivalent, and immutability here is already guaranteed by construction
///   (every AVC result type uses `final` fields and `List.unmodifiable`).
/// - In place of `JSON.stringify(result)` (used only to prove the two calls
///   produced byte-identical structures), a local deterministic string
///   summary of every scalar field is used for the same purpose.
library;

import 'dart:typed_data';

import 'package:aval_format/src/avc/index.dart';
import 'package:aval_format/src/errors.dart';
import 'package:test/test.dart';

import 'avc_fixture.dart';

const List<int> _seeds = [0x5a170c5e];

void main() {
  group('seeded hostile AVC mutation corpus', () {
    for (final seed in _seeds) {
      test(
        'returns one deterministic frozen result or PROFILE_INVALID without leaks for seed $seed',
        () {
          final random = _xorshift32(seed);
          for (var iteration = 0; iteration < 2048; iteration += 1) {
            final input = _cloneInput();
            final unit = input.units[(random() * input.units.length).floor()];
            final accessUnit =
                unit.accessUnits[(random() * unit.accessUnits.length).floor()];
            accessUnit.bytes = _mutate(accessUnit.bytes, random);

            final first = _inspectOutcome(input);
            final second = _inspectOutcome(input);
            expect(second, equals(first));
            if (!first.ok) {
              expect(first.errorCode, FormatErrorCode.profileInvalid);
            }
          }
        },
      );
    }
  });
}

MutableInspectionInput _cloneInput() {
  final source = validInspectionInput();
  return MutableInspectionInput(
    profile: MutableProfile(
      codedWidth: source.profile.codedWidth,
      codedHeight: source.profile.codedHeight,
      frameRate: MutableFrameRate(
        numerator: source.profile.frameRate.numerator,
        denominator: source.profile.frameRate.denominator,
      ),
      averageBitrate: source.profile.averageBitrate,
      peakBitrate: source.profile.peakBitrate,
      cpbBufferBits: source.profile.cpbBufferBits,
      requireBt709LimitedRange: source.profile.requireBt709LimitedRange,
      quantizationPolicy: source.profile.quantizationPolicy,
      expectedDecodedStorageRect: source.profile.expectedDecodedStorageRect,
    ),
    units: source.units
        .map(
          (unit) => MutableUnit(
            id: unit.id,
            accessUnits: unit.accessUnits
                .map(
                  (sample) => MutableAccessUnit(
                    key: sample.key,
                    bytes: Uint8List.fromList(sample.bytes),
                  ),
                )
                .toList(),
          ),
        )
        .toList(),
  );
}

Uint8List _mutate(Uint8List bytes, double Function() random) {
  final operation = (random() * 5).floor();
  final index = (random() * (bytes.isNotEmpty ? bytes.length : 1)).floor();
  if (operation == 0 && bytes.isNotEmpty) {
    final result = Uint8List.fromList(bytes);
    final target = index % result.length;
    result[target] = result[target] ^ (1 << (random() * 8).floor());
    return result;
  }
  if (operation == 1) {
    return bytes.sublist(0, index % (bytes.length + 1));
  }
  if (operation == 2 && bytes.length > 1) {
    final start = index % bytes.length;
    final bound = 8 < (bytes.length - start) ? 8 : (bytes.length - start);
    final count = 1 + (random() * bound).floor();
    final result = Uint8List(bytes.length - count);
    result.setRange(0, start, bytes.sublist(0, start));
    result.setRange(start, result.length, bytes.sublist(start + count));
    return result;
  }
  if (operation == 3) {
    final count = 1 + (random() * 8).floor();
    final at = index % (bytes.length + 1);
    final result = Uint8List(bytes.length + count);
    result.setRange(0, at, bytes.sublist(0, at));
    for (var offset = 0; offset < count; offset += 1) {
      result[at + offset] = (random() * 256).floor();
    }
    result.setRange(at + count, result.length, bytes.sublist(at));
    return result;
  }
  return Uint8List.fromList(bytes);
}

class _InspectOutcome {
  const _InspectOutcome.ok(this.summary)
      : ok = true,
        errorCode = null,
        errorMessage = null,
        errorPath = null,
        errorOffset = null;

  const _InspectOutcome.error(
    this.errorCode,
    this.errorMessage,
    this.errorPath,
    this.errorOffset,
  )   : ok = false,
        summary = null;

  final bool ok;
  final String? summary;
  final FormatErrorCode? errorCode;
  final String? errorMessage;
  final String? errorPath;
  final int? errorOffset;

  @override
  bool operator ==(Object other) =>
      other is _InspectOutcome &&
      other.ok == ok &&
      other.summary == summary &&
      other.errorCode == errorCode &&
      other.errorMessage == errorMessage &&
      other.errorPath == errorPath &&
      other.errorOffset == errorOffset;

  @override
  int get hashCode =>
      Object.hash(ok, summary, errorCode, errorMessage, errorPath, errorOffset);

  @override
  String toString() =>
      ok ? '_InspectOutcome.ok($summary)' : '_InspectOutcome.error($errorCode, $errorMessage)';
}

_InspectOutcome _inspectOutcome(MutableInspectionInput input) {
  try {
    final result = inspectAvcAnnexBRendition(input.toInspectionInput());
    return _InspectOutcome.ok(_summarizeInspection(result));
  } on FormatError catch (error) {
    return _InspectOutcome.error(error.code, error.message, error.path, error.offset);
  }
}

String _summarizeInspection(AvcRenditionInspection result) {
  final buffer = StringBuffer();
  final parameterSet = result.parameterSet;
  buffer.write('mbpf=${result.macroblocksPerFrame};');
  buffer.write(
    'profileIdc=${parameterSet.profileIdc};cs2=${parameterSet.constraintSet2};'
    'level=${parameterSet.levelIdc};w=${parameterSet.codedWidth};h=${parameterSet.codedHeight};',
  );
  final crop = parameterSet.crop;
  buffer.write(
    'crop=${crop.left},${crop.right},${crop.top},${crop.bottom},'
    '${crop.visibleWidth},${crop.visibleHeight};',
  );
  buffer.write(
    'maxRef=${parameterSet.maxNumRefFrames};maxReorder=${parameterSet.maxNumReorderFrames};'
    'maxDpb=${parameterSet.maxDecFrameBuffering};hrd=${parameterSet.hrdPresent};'
    'ffr=${parameterSet.fixedFrameRate};sqAspect=${parameterSet.squareSampleAspect};',
  );
  final color = parameterSet.color;
  buffer.write(
    'color=${color.fullRange},${color.colourPrimaries},'
    '${color.transferCharacteristics},${color.matrixCoefficients};',
  );
  for (final unit in result.units) {
    buffer.write('unit(${unit.id}):');
    for (final frame in unit.frames) {
      buffer.write(
        '[f=${frame.frameIndex},k=${frame.key},idr=${frame.idr},st=${frame.sliceType},'
        'sc=${frame.sliceCount},nals=${frame.nalUnitTypes.join(",")}]',
      );
    }
  }
  return buffer.toString();
}

double Function() _xorshift32(int seed) {
  var state = seed & 0xFFFFFFFF;
  return () {
    state = (state ^ ((state << 13) & 0xFFFFFFFF)) & 0xFFFFFFFF;
    state = (state ^ (state >> 17)) & 0xFFFFFFFF;
    state = (state ^ ((state << 5) & 0xFFFFFFFF)) & 0xFFFFFFFF;
    return state / 4294967296.0;
  };
}
