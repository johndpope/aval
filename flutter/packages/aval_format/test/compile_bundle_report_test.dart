// Dart port of `packages/format/test/compile-bundle-report.test.ts`.
//
// The module is imported directly (not via the package barrel) while the
// top-level barrel is in flux, per the porting brief. These tests exercise
// `parseCompileBundleReport`; running them requires the concurrently-authored
// `lib/src/video/codec-string.dart` dependency to be present.

import 'package:aval_format/src/compile_bundle_report.dart';
import 'package:test/test.dart';

/// Mirrors the TS `.toThrow(/pattern/)` assertions: the port throws a
/// [FormatException] whose message is `compile bundle report: <path> <message>`.
Matcher _reportError(String pattern) => throwsA(
      isA<FormatException>()
          .having((e) => e.toString(), 'message', matches(pattern)),
    );

void main() {
  group('compile bundle report', () {
    test('validates, detaches, and rebuilds the browser-facing report contract',
        () {
      final source = validReport();
      final parsed = parseCompileBundleReport(source);

      final asset = parsed.assets[0];
      expect(asset.codec, 'h264');
      expect(asset.path, 'h264.avl');
      expect(asset.codecString, 'avc1.64001E');

      final encoding = parsed.encodings[0];
      expect(encoding, isA<CompileBundleReportH264Encoding>());
      encoding as CompileBundleReportH264Encoding;
      expect(encoding.preset, 'medium');
      expect(encoding.renditions, hasLength(1));
      final rendition = encoding.renditions[0];
      expect(rendition.id, 'video.main');
      expect(rendition.width, 640);
      expect(rendition.height, 360);
      expect(rendition.crf, 30);

      // Detachment: the returned lists are unmodifiable copies.
      expect(() => parsed.assets.add(asset), throwsUnsupportedError);
      expect(() => parsed.encodings[0].renditions.add(rendition),
          throwsUnsupportedError);

      // Mutating the source after parsing must not affect the parsed report.
      ((source['assets']! as List<Object?>)[0]! as Map<String, Object?>)[
          'bytes'] = 1;
      expect(parsed.assets[0].bytes, 1234);
    });

    test('rejects codec strings outside the supported AVAL codec contract', () {
      final source = validReport();
      final asset =
          (source['assets']! as List<Object?>)[0]! as Map<String, Object?>;
      asset['codecString'] = 'avc1.000000';
      asset['type'] = 'application/vnd.aval; codecs="avc1.000000"';
      expect(() => parseCompileBundleReport(source),
          _reportError(r'codecString.*supported codec string'));
    });

    test('rejects asset and encoding order drift', () {
      final source = validReport();
      final asset =
          (source['assets']! as List<Object?>)[0]! as Map<String, Object?>;
      asset['codec'] = 'vp9';
      asset['path'] = 'vp9.avl';
      expect(() => parseCompileBundleReport(source),
          _reportError(r'must match the encoding'));
    });

    test('rejects integrity metadata that disagrees with the SHA-256 digest',
        () {
      final source = validReport();
      final asset =
          (source['assets']! as List<Object?>)[0]! as Map<String, Object?>;
      asset['integrity'] = 'sha256-AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=';
      expect(() => parseCompileBundleReport(source),
          _reportError(r'integrity.*declared sha256 digest'));
    });

    test('accepts the compiler empty arguments and full path-free text limits',
        () {
      final source = validReport();
      final invocation =
          (source['invocations']! as List<Object?>)[0]! as Map<String, Object?>;
      invocation['arguments'] = <String>['', 'x' * (17 * 1024)];
      source['warnings'] = <String>['w' * (5 * 1024)];

      final parsed = parseCompileBundleReport(source);

      expect(parsed.invocations[0].arguments[0], '');
      expect(parsed.invocations[0].arguments[1], hasLength(17 * 1024));
      expect(parsed.warnings[0], hasLength(5 * 1024));
    });

    test('enforces the compiler warning-count limit', () {
      final source = validReport();
      source['warnings'] = List<String>.generate(4097, (_) => 'warning');

      expect(() => parseCompileBundleReport(source),
          _reportError(r'warnings.*0 through 4096 entries'));
    });

    test('rejects presets outside the compiler encoder allowlists', () {
      final source = validReport();
      final encoding =
          (source['encodings']! as List<Object?>)[0]! as Map<String, Object?>;
      encoding['preset'] = 'not-an-x264-preset';

      expect(() => parseCompileBundleReport(source),
          _reportError(r'preset.*must be one of'));
    });

    test('rejects malformed toolchain provenance', () {
      final source = validReport();
      source['toolchain'] = <String, Object?>{};

      expect(() => parseCompileBundleReport(source),
          _reportError(r'toolchain\.ffmpeg.*required'));
    });

    test('requires source markup derived from the ordered assets', () {
      final source = validReport();
      source['sourceMarkup'] = '<source>';

      expect(() => parseCompileBundleReport(source),
          _reportError(r'sourceMarkup.*ordered asset metadata'));
    });
  });
}

Map<String, Object?> validReport() {
  final asset = <String, Object?>{
    'codec': 'h264',
    'path': 'h264.avl',
    'bytes': 1234,
    'sha256': '0' * 64,
    'codecString': 'avc1.64001E',
    'type': 'application/vnd.aval; codecs="avc1.64001E"',
    'integrity': 'sha256-${'A' * 43}=',
  };
  return <String, Object?>{
    'reportVersion': '1.0',
    'assets': <Object?>[asset],
    'encodings': <Object?>[
      <String, Object?>{
        'codec': 'h264',
        'preset': 'medium',
        'renditions': <Object?>[
          <String, Object?>{
            'id': 'video.main',
            'width': 640,
            'height': 360,
            'crf': 30,
          },
        ],
      },
    ],
    'invocations': <Object?>[
      <String, Object?>{
        'operation': 'h264:video.main:loop:encode',
        'tool': 'ffmpeg',
        'arguments': <String>['-c:v', 'libx264'],
      },
    ],
    'warnings': <String>[],
    'toolchain': validToolchain(),
    'sourceMarkup':
        '<source src="h264.avl" type=\'application/vnd.aval; codecs="avc1.64001E"\' integrity="sha256-${'A' * 43}=">',
  };
}

Map<String, Object?> validToolchain() => <String, Object?>{
      'ffmpeg': <String, Object?>{
        'executableSha256': '1' * 64,
        'executableIdentity': executableIdentity('1'),
        'version': 'ffmpeg version 8.0-test',
        'versionOutputSha256': '2' * 64,
        'configurationSha256': '3' * 64,
        'encodersOutputSha256': '4' * 64,
        'calibrationSha256': '5' * 64,
      },
      'ffprobe': <String, Object?>{
        'executableSha256': '6' * 64,
        'executableIdentity': executableIdentity('2'),
        'version': 'ffprobe version 8.0-test',
        'versionOutputSha256': '7' * 64,
      },
      'aggregateMemoryLimit': 'derived',
    };

Map<String, Object?> executableIdentity(String inode) => <String, Object?>{
      'device': '1',
      'inode': inode,
      'size': 123,
      'mtimeNanoseconds': '1000',
      'ctimeNanoseconds': '1001',
    };
