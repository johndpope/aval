// Dart port of packages/format/test/manifest-schema.test.ts (1.0).
//
// TS-only assertions with no Dart analog are adapted: `toEqual(source)` /
// `not.toBe(source)` become field-by-field checks (the schema returns a typed
// `CompiledManifest`, not a Map), and `expectDeepFrozen` is dropped (Dart has
// no `Object.isFrozen`; the model is immutable by construction).
import 'dart:collection';

import 'package:aval_format/src/errors.dart';
import 'package:aval_format/src/manifest_schema.dart';
import 'package:aval_format/src/model.dart';
import 'package:test/test.dart';

import 'manifest_fixture.dart';

Object? _deepClone(Object? value) {
  if (value is Map) {
    return <String, Object?>{
      for (final entry in value.entries) entry.key as String: _deepClone(entry.value),
    };
  }
  if (value is List) {
    return <Object?>[for (final entry in value) _deepClone(entry)];
  }
  return value;
}

Map<String, Object?> _mutableManifest() => _deepClone(validManifest()) as Map<String, Object?>;

void _configureCodec(Map<String, Object?> manifest, String codec, [int bitDepth = 8]) {
  manifest['codec'] = codec;
  manifest['bitstream'] =
      codec == 'vp9' ? 'frame' : (codec == 'av1' ? 'low-overhead' : 'annex-b');
  final rendition = (manifest['renditions'] as List)[0] as Map<String, Object?>;
  rendition['codec'] = {
    'h264': 'avc1.640020',
    'h265': 'hvc1.1.6.L93.B0',
    'vp9': 'vp09.00.10.08',
    'av1': bitDepth == 10
        ? 'av01.0.08M.10.0.110.01.01.01.0'
        : 'av01.0.08M.08.0.110.01.01.01.0',
  }[codec];
  rendition['bitDepth'] = bitDepth;
}

FormatError _expectManifestInvalid(Object? value, [String? path]) {
  try {
    validateCompiledManifest(value);
  } on FormatError catch (error) {
    expect(error.code, FormatErrorCode.manifestInvalid);
    if (path != null) expect(error.path, path);
    return error;
  }
  fail('expected manifest validation to fail');
}

/// A `Map` whose enumeration throws, mirroring the TS `new Proxy({}, { ownKeys()
/// { throw } })` hostile record.
class _ThrowingMap extends MapBase<String, Object?> {
  @override
  Object? operator [](Object? key) => throw StateError('hostile');
  @override
  void operator []=(String key, Object? value) {}
  @override
  void clear() {}
  @override
  Iterable<String> get keys => throw StateError('hostile');
  @override
  Object? remove(Object? key) => null;
}

void main() {
  group('validateCompiledManifest 1.0', () {
    test('validates, detaches, and freezes the canonical manifest', () {
      final result = validateCompiledManifest(validManifest());
      expect(result.formatVersion, '1.0');
      expect(result.generator, 'aval-tests');
      expect(result.codec, 'h264');
      expect(result.bitstream, 'annex-b');
      expect(result.layout, 'opaque');
      expect(result.renditions.map((r) => r.id).toList(), ['video']);
      expect(result.units.length, 6);
      expect(result.states.length, 3);
      expect(result.edges.length, 5);
    });

    test('supports the four codec families and AV1 10-bit', () {
      for (final pair in const [
        ['h264', 8],
        ['h265', 8],
        ['vp9', 8],
        ['av1', 8],
        ['av1', 10],
      ]) {
        final codec = pair[0] as String;
        final bitDepth = pair[1] as int;
        final manifest = _mutableManifest();
        _configureCodec(manifest, codec, bitDepth);
        expect(validateCompiledManifest(manifest).renditions[0].bitDepth, bitDepth);
      }
    });

    test('requires exact codec, bitstream, and bit-depth agreement', () {
      final mutations = <void Function(Map<String, Object?>)>[
        (value) {
          value['bitstream'] = 'frame';
        },
        (value) {
          ((value['renditions'] as List)[0] as Map<String, Object?>)['codec'] = 'vp09.00.10.08';
        },
        (value) {
          ((value['renditions'] as List)[0] as Map<String, Object?>)['bitDepth'] = 10;
        },
        (value) {
          _configureCodec(value, 'av1', 10);
          ((value['renditions'] as List)[0] as Map<String, Object?>)['codec'] =
              'av01.0.08M.08.0.110.01.01.01.0';
        },
      ];
      for (final mutate in mutations) {
        final manifest = _mutableManifest();
        mutate(manifest);
        _expectManifestInvalid(manifest);
      }
    });

    test('supports and strictly validates the shared packed-alpha layout', () {
      final manifest = _mutableManifest();
      manifest['layout'] = 'packed-alpha';
      final rendition = (manifest['renditions'] as List)[0] as Map<String, Object?>;
      rendition['codedHeight'] = 32;
      rendition['alphaLayout'] = <String, Object?>{
        'type': 'stacked',
        'colorRect': [0, 0, 2, 2],
        'alphaRect': [0, 10, 2, 2],
      };
      (manifest['limits'] as Map<String, Object?>)['decodedPixelBytes'] = 16 * 32 * 4;
      (manifest['limits'] as Map<String, Object?>)['runtimeWorkingSetBytes'] = 16 * 32 * 4;
      expect(validateCompiledManifest(manifest).layout, 'packed-alpha');

      ((rendition['alphaLayout'] as Map<String, Object?>)['alphaRect'] as List)[1] = 9;
      _expectManifestInvalid(manifest, 'renditions[0].alphaLayout.alphaRect');
    });

    test('preserves authored rendition quality order and rejects duplicate IDs', () {
      final manifest = _mutableManifest();
      final renditions = manifest['renditions'] as List;
      final high = renditions[0] as Map<String, Object?>;
      final low = <String, Object?>{
        ...high,
        'id': 'low',
        'bitrate': {'average': 500, 'peak': 1000},
      };
      manifest['renditions'] = [high, low];
      var start = 18;
      for (final entry in manifest['units'] as List) {
        final unit = entry as Map<String, Object?>;
        final frameCount = unit['frameCount'] as int;
        (unit['chunks'] as List).add({
          'rendition': 'low',
          'chunkStart': start,
          'chunkCount': frameCount,
          'frameCount': frameCount,
          'sha256': '0'.padRight(64, '0'),
        });
        start += frameCount;
      }
      expect(
        validateCompiledManifest(manifest).renditions.map((r) => r.id).toList(),
        ['video', 'low'],
      );
      ((manifest['renditions'] as List)[1] as Map<String, Object?>)['id'] = 'video';
      _expectManifestInvalid(manifest, 'renditions[1].id');
    });

    test('requires canonical decode-order spans and independent frame coverage metadata', () {
      final mutations = <void Function(Map<String, Object?>)>[
        (value) {
          ((((value['units'] as List)[0] as Map<String, Object?>)['chunks'] as List)[0]
              as Map<String, Object?>)['chunkStart'] = 1;
        },
        (value) {
          ((((value['units'] as List)[0] as Map<String, Object?>)['chunks'] as List)[0]
              as Map<String, Object?>)['chunkCount'] = 0;
        },
        (value) {
          ((((value['units'] as List)[0] as Map<String, Object?>)['chunks'] as List)[0]
              as Map<String, Object?>)['frameCount'] = 3;
        },
        (value) {
          ((((value['units'] as List)[0] as Map<String, Object?>)['chunks'] as List)[0]
              as Map<String, Object?>)['rendition'] = 'other';
        },
      ];
      for (final mutate in mutations) {
        final manifest = _mutableManifest();
        mutate(manifest);
        _expectManifestInvalid(manifest);
      }
    });

    test('rejects old wire/profile fields instead of dispatching versions', () {
      final oldVersion = _mutableManifest();
      oldVersion['formatVersion'] = '0.1';
      _expectManifestInvalid(oldVersion, 'formatVersion');

      final legacyProfile = _mutableManifest();
      ((legacyProfile['renditions'] as List)[0] as Map<String, Object?>)['profile'] =
          'reference-rgba-v0';
      _expectManifestInvalid(legacyProfile);

      final legacySamples = _mutableManifest();
      final unit0 = (legacySamples['units'] as List)[0] as Map<String, Object?>;
      unit0['samples'] = unit0['chunks'];
      unit0.remove('chunks');
      _expectManifestInvalid(legacySamples);
    });

    test('honors chunk, frame, rendition, unit, and blob budgets', () {
      final budgetSets = <Map<String, int>>[
        {'maxChunkRecords': 17},
        {'maxTotalUnitFrames': 17},
        {'maxRenditions': 0},
        {'maxUnits': 5},
        {'maxBlobRanges': 5},
      ];
      for (final budgets in budgetSets) {
        expect(
          () => validateCompiledManifest(validManifest(), FormatOptions(budgets: budgets)),
          throwsA(isA<FormatError>()),
        );
      }
    });

    test('validates the graph-heavy ceiling fixture', () {
      final result = validateCompiledManifest(limitManifest());
      expect(result.units.length, 96);
      expect(result.states.length, 32);
      expect(result.edges.length, 64);
    });

    test('never leaks built-in errors for hostile input', () {
      expect(() => validateCompiledManifest(null), throwsA(isA<FormatError>()));
      expect(() => validateCompiledManifest(_ThrowingMap()), throwsA(isA<FormatError>()));
    });
  });
}
