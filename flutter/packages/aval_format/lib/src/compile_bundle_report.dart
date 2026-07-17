/// Validate, detach, and immutably rebuild one compiler-published build
/// report (the browser-facing `build.json` contract).
///
/// Dart port of `packages/format/src/compile-bundle-report.ts`. The TypeScript
/// source operates on an `unknown` in-memory JavaScript value and rejects
/// malformed input by throwing a native `TypeError` whose message is
/// `compile bundle report: <path> <message>`. There is no Dart analogue of a
/// message-carrying `TypeError`, so the faithful equivalent here throws
/// `dart:core`'s [FormatException] (semantically "data does not have the
/// expected format"), preserving the exact message string. See the `_invalid`
/// helper below.
///
/// Where the TypeScript relied on structural/anonymous object types, this port
/// introduces named classes to match the codebase's "interfaces -> immutable
/// classes" convention: [CompileBundleReportLimits] (the frozen limits
/// object), [CompileBundleReportAv1Tiles] (the inline `{columns, rows}` type),
/// and [CompileBundleReportFfmpegTool] (the `CompileBundleReportTool &
/// {...three extra digests}` intersection).
library;

import 'checked_integer.dart' show maxSafeInteger;
import 'canonical_json.dart'
    show CanonicalJsonWriteLimits, serializeCanonicalJsonWithLimits;
import 'constants.dart' show identifierPattern, sha256HexPattern;
import 'model.dart' show VideoBitDepth, VideoCodec;
import 'package:aval_format/src/video/codec_string.dart'
    show isVideoCodecString, videoCodecs;

// --- Local pattern constants (mirroring the TS module-level regexes). ---
// Only the non-shared patterns are defined here; SHA-256 hex and identifier
// patterns are reused from `constants.dart` exactly as the TS imports them
// from `./constants.js`.

final RegExp _integrity = RegExp(r'^sha256-[A-Za-z0-9+/]{43}=$', unicode: true);
final RegExp _pathOrUrl = RegExp(
  r'''(?:^|[\s"'(=])(?:https?://|file:|[A-Za-z]:[\\/]|\\\\|/(?!/)|\.\.?[\\/]|~[\\/])''',
  unicode: true,
);
final RegExp _controlCharacter =
    RegExp(r'[\u0000-\u001f\u007f]', unicode: true);
final RegExp _decimalText = RegExp(r'^(?:0|[1-9][0-9]*)$', unicode: true);

// The TS error message embeds `String(pattern)`, i.e. the JavaScript regex
// literal source with flags. These strings reproduce that exact rendering.
const String _integrityText = r'/^sha256-[A-Za-z0-9+/]{43}=$/u';
const String _decimalTextText = r'/^(?:0|[1-9][0-9]*)$/u';
const String _sha256Text = r'/^[0-9a-f]{64}$/';
const String _identifierText = r'/^[a-z][a-z0-9._-]{0,63}$/';

const String _base64Alphabet =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

const List<String> compileBundleH264Presets = [
  'ultrafast',
  'superfast',
  'veryfast',
  'faster',
  'fast',
  'medium',
  'slow',
  'slower',
  'veryslow',
  'placebo',
];
const List<String> compileBundleH265Presets = compileBundleH264Presets;
const List<String> compileBundleVp9Deadlines = ['best', 'good', 'realtime'];

/// The frozen `COMPILE_BUNDLE_REPORT_LIMITS` object. `maxAssets` is
/// `videoCodecs.length` exactly as in TS, so this is a `final` (not `const`)
/// binding.
class CompileBundleReportLimits {
  const CompileBundleReportLimits({
    required this.maxAssets,
    required this.maxInvocations,
    required this.maxInvocationArguments,
    required this.maxWarnings,
    required this.maxOperationCodeUnits,
    required this.maxFreeTextCodeUnits,
    required this.serialization,
  });

  final int maxAssets;
  final int maxInvocations;
  final int maxInvocationArguments;
  final int maxWarnings;
  final int maxOperationCodeUnits;
  final int maxFreeTextCodeUnits;

  /// The `serialization` sub-object maps 1:1 onto the write-limits type
  /// consumed by [serializeCanonicalJsonWithLimits].
  final CanonicalJsonWriteLimits serialization;
}

final CompileBundleReportLimits compileBundleReportLimits =
    CompileBundleReportLimits(
  maxAssets: videoCodecs.length,
  maxInvocations: 16384,
  maxInvocationArguments: 512,
  maxWarnings: 4096,
  maxOperationCodeUnits: 256,
  maxFreeTextCodeUnits: 32 * 1024,
  serialization: const CanonicalJsonWriteLimits(
    maxBytes: 64 * 1024 * 1024,
    maxDepth: 64,
    maxNodes: 2000000,
    maxStringBytes: 1024 * 1024,
  ),
);

const List<String> _topLevelKeys = [
  'reportVersion',
  'assets',
  'encodings',
  'invocations',
  'warnings',
  'toolchain',
  'sourceMarkup',
];

// --- Value types (TS interfaces -> immutable Dart classes). ---

class CompileBundleReportAsset {
  const CompileBundleReportAsset({
    required this.codec,
    required this.path,
    required this.bytes,
    required this.sha256,
    required this.codecString,
    required this.type,
    required this.integrity,
  });

  final VideoCodec codec;

  /// `${codec}.avl`.
  final String path;
  final int bytes;
  final String sha256;
  final String codecString;

  /// `application/vnd.aval; codecs="${codecString}"`.
  final String type;

  /// `sha256-${base64}`.
  final String integrity;
}

class CompileBundleReportRendition {
  const CompileBundleReportRendition({
    required this.id,
    required this.width,
    required this.height,
    required this.crf,
  });

  final String id;
  final int width;
  final int height;
  final int crf;
}

/// TS union `CompileBundleReportEncoding`. The internal
/// `CompileBundleReportEncodingBase` interface is folded into this sealed base.
sealed class CompileBundleReportEncoding {
  const CompileBundleReportEncoding({
    required this.codec,
    required this.renditions,
  });

  final VideoCodec codec;
  final List<CompileBundleReportRendition> renditions;
}

class CompileBundleReportH264Encoding extends CompileBundleReportEncoding {
  const CompileBundleReportH264Encoding({
    required this.preset,
    required super.renditions,
  }) : super(codec: 'h264');

  final String preset;
}

class CompileBundleReportH265Encoding extends CompileBundleReportEncoding {
  const CompileBundleReportH265Encoding({
    required this.preset,
    required this.threads,
    required super.renditions,
  }) : super(codec: 'h265');

  final String preset;
  final int threads;
}

class CompileBundleReportVp9Encoding extends CompileBundleReportEncoding {
  const CompileBundleReportVp9Encoding({
    required this.deadline,
    required this.cpuUsed,
    required this.threads,
    required super.renditions,
  }) : super(codec: 'vp9');

  final String deadline;
  final int cpuUsed;
  final int threads;
}

/// The inline `{ columns, rows }` tiles object of an AV1 encoding.
class CompileBundleReportAv1Tiles {
  const CompileBundleReportAv1Tiles({
    required this.columns,
    required this.rows,
  });

  final int columns;
  final int rows;
}

class CompileBundleReportAv1Encoding extends CompileBundleReportEncoding {
  const CompileBundleReportAv1Encoding({
    required this.bitDepth,
    required this.cpuUsed,
    required this.tiles,
    required this.rowMt,
    required this.threads,
    required super.renditions,
  }) : super(codec: 'av1');

  /// `8 | 10`.
  final VideoBitDepth bitDepth;
  final int cpuUsed;
  final CompileBundleReportAv1Tiles tiles;
  final bool rowMt;
  final int threads;
}

class CompileBundleReportInvocation {
  const CompileBundleReportInvocation({
    required this.operation,
    required this.tool,
    required this.arguments,
  });

  final String operation;

  /// `"ffmpeg" | "ffprobe"`.
  final String tool;
  final List<String> arguments;
}

class CompileBundleReportExecutableIdentity {
  const CompileBundleReportExecutableIdentity({
    required this.device,
    required this.inode,
    required this.size,
    required this.mtimeNanoseconds,
    required this.ctimeNanoseconds,
  });

  final String device;
  final String inode;
  final int size;
  final String mtimeNanoseconds;
  final String ctimeNanoseconds;
}

class CompileBundleReportTool {
  const CompileBundleReportTool({
    required this.executableSha256,
    required this.executableIdentity,
    required this.version,
    required this.versionOutputSha256,
  });

  final String executableSha256;
  final CompileBundleReportExecutableIdentity executableIdentity;
  final String version;
  final String versionOutputSha256;
}

/// `toolchain.ffmpeg`: a [CompileBundleReportTool] with three extra digests
/// (the TS intersection type).
class CompileBundleReportFfmpegTool extends CompileBundleReportTool {
  const CompileBundleReportFfmpegTool({
    required super.executableSha256,
    required super.executableIdentity,
    required super.version,
    required super.versionOutputSha256,
    required this.configurationSha256,
    required this.encodersOutputSha256,
    required this.calibrationSha256,
  });

  final String configurationSha256;
  final String encodersOutputSha256;
  final String calibrationSha256;
}

class CompileBundleReportToolchain {
  const CompileBundleReportToolchain({
    required this.ffmpeg,
    required this.ffprobe,
  });

  final CompileBundleReportFfmpegTool ffmpeg;
  final CompileBundleReportTool ffprobe;

  /// Always `"derived"`.
  String get aggregateMemoryLimit => 'derived';
}

class ParsedCompileBundleReport {
  const ParsedCompileBundleReport({
    required this.assets,
    required this.encodings,
    required this.invocations,
    required this.warnings,
    required this.toolchain,
    required this.sourceMarkup,
  });

  /// Always `"1.0"`.
  String get reportVersion => '1.0';
  final List<CompileBundleReportAsset> assets;
  final List<CompileBundleReportEncoding> encodings;
  final List<CompileBundleReportInvocation> invocations;
  final List<String> warnings;
  final CompileBundleReportToolchain toolchain;
  final String sourceMarkup;
}

/// Validate, detach, and recursively rebuild one compiler-published build.json.
ParsedCompileBundleReport parseCompileBundleReport(Object? value) {
  final input = _record(value, 'report');
  _exactKeys(input, _topLevelKeys, 'report');
  if (input['reportVersion'] != '1.0') {
    _invalid('report.reportVersion', 'must be 1.0');
  }

  final encodings = _cloneEncodings(input['encodings']);
  final assets = _cloneAssets(input['assets'], encodings);
  final invocations = _cloneInvocations(input['invocations']);
  final warningInputs = _boundedArray(
    input['warnings'],
    'report.warnings',
    0,
    compileBundleReportLimits.maxWarnings,
  );
  final warnings = <String>[];
  for (var index = 0; index < warningInputs.length; index += 1) {
    warnings.add(_pathFreeText(
      warningInputs[index],
      'report.warnings[$index]',
      compileBundleReportLimits.maxFreeTextCodeUnits,
    ));
  }
  final toolchain = _cloneToolchain(input['toolchain']);
  final sourceMarkup = createCompileBundleSourceMarkup(assets);
  if (input['sourceMarkup'] != sourceMarkup) {
    _invalid('report.sourceMarkup', 'must match the ordered asset metadata');
  }

  final report = ParsedCompileBundleReport(
    assets: assets,
    encodings: encodings,
    invocations: invocations,
    warnings: List.unmodifiable(warnings),
    toolchain: toolchain,
    sourceMarkup: sourceMarkup,
  );
  try {
    serializeCanonicalJsonWithLimits(
      _reportToCanonicalValue(report),
      compileBundleReportLimits.serialization,
    );
  } catch (_) {
    _invalid('report', 'exceeds canonical serialization limits');
  }
  return report;
}

List<CompileBundleReportAsset> _cloneAssets(
  Object? value,
  List<CompileBundleReportEncoding> encodings,
) {
  final inputs = _boundedArray(
    value,
    'report.assets',
    1,
    compileBundleReportLimits.maxAssets,
  );
  if (inputs.length != encodings.length) {
    _invalid('report.assets', 'must match the encoding count');
  }
  final seen = <VideoCodec>{};
  final result = <CompileBundleReportAsset>[];
  for (var index = 0; index < inputs.length; index += 1) {
    final path = 'report.assets[$index]';
    final input = _record(inputs[index], path);
    _exactKeys(
      input,
      const [
        'codec',
        'path',
        'bytes',
        'sha256',
        'codecString',
        'type',
        'integrity',
      ],
      path,
    );
    final codec = _codecValue(input['codec'], '$path.codec');
    if (seen.contains(codec)) _invalid('$path.codec', 'must be unique');
    seen.add(codec);
    final encoding = index < encodings.length ? encodings[index] : null;
    if (encoding == null || codec != encoding.codec) {
      _invalid('$path.codec', 'must match the encoding in the same position');
    }
    final assetPath = '$codec.avl';
    if (input['path'] != assetPath) _invalid('$path.path', 'must be $assetPath');
    final bytes = _integer(input['bytes'], '$path.bytes', 1, maxSafeInteger);
    final sha256Value = _sha256(input['sha256'], '$path.sha256');
    final bitDepth =
        encoding is CompileBundleReportAv1Encoding ? encoding.bitDepth : 8;
    final codecStringValue = input['codecString'];
    if (!isVideoCodecString(codecStringValue, codec, bitDepth)) {
      _invalid('$path.codecString', 'is not a supported codec string');
    }
    final codecString = codecStringValue as String;
    final type = 'application/vnd.aval; codecs="$codecString"';
    if (input['type'] != type) _invalid('$path.type', 'must match codecString');
    final integrity = _stringPattern(
        input['integrity'], _integrity, _integrityText, '$path.integrity');
    if (integrity != _integrityForSha256(sha256Value)) {
      _invalid('$path.integrity', 'must encode the declared sha256 digest');
    }
    result.add(CompileBundleReportAsset(
      codec: codec,
      path: assetPath,
      bytes: bytes,
      sha256: sha256Value,
      codecString: codecString,
      type: type,
      integrity: integrity,
    ));
  }
  return List.unmodifiable(result);
}

List<CompileBundleReportEncoding> _cloneEncodings(Object? value) {
  final inputs = _boundedArray(
    value,
    'report.encodings',
    1,
    compileBundleReportLimits.maxAssets,
  );
  final seen = <VideoCodec>{};
  final result = <CompileBundleReportEncoding>[];
  for (var index = 0; index < inputs.length; index += 1) {
    final path = 'report.encodings[$index]';
    final input = _record(inputs[index], path);
    final codec = _codecValue(input['codec'], '$path.codec');
    if (seen.contains(codec)) _invalid('$path.codec', 'must be unique');
    seen.add(codec);
    final renditions = _cloneRenditions(input['renditions'], path, codec);
    switch (codec) {
      case 'h264':
        _exactKeys(input, const ['codec', 'preset', 'renditions'], path);
        result.add(CompileBundleReportH264Encoding(
          preset:
              _oneOf(input['preset'], compileBundleH264Presets, '$path.preset'),
          renditions: renditions,
        ));
      case 'h265':
        _exactKeys(
            input, const ['codec', 'preset', 'threads', 'renditions'], path);
        result.add(CompileBundleReportH265Encoding(
          preset:
              _oneOf(input['preset'], compileBundleH265Presets, '$path.preset'),
          threads: _integer(input['threads'], '$path.threads', 1, 64),
          renditions: renditions,
        ));
      case 'vp9':
        _exactKeys(
          input,
          const ['codec', 'deadline', 'cpuUsed', 'threads', 'renditions'],
          path,
        );
        result.add(CompileBundleReportVp9Encoding(
          deadline: _oneOf(
              input['deadline'], compileBundleVp9Deadlines, '$path.deadline'),
          cpuUsed: _integer(input['cpuUsed'], '$path.cpuUsed', -8, 8),
          threads: _integer(input['threads'], '$path.threads', 1, 64),
          renditions: renditions,
        ));
      case 'av1':
        _exactKeys(
          input,
          const [
            'codec',
            'bitDepth',
            'cpuUsed',
            'tiles',
            'rowMt',
            'threads',
            'renditions',
          ],
          path,
        );
        final tiles = _record(input['tiles'], '$path.tiles');
        _exactKeys(tiles, const ['columns', 'rows'], '$path.tiles');
        final columns = _powerOfTwo(tiles['columns'], '$path.tiles.columns');
        final rows = _powerOfTwo(tiles['rows'], '$path.tiles.rows');
        if (columns * rows > 64) {
          _invalid('$path.tiles', 'product must be at most 64');
        }
        final bitDepthValue = input['bitDepth'];
        if (bitDepthValue != 8 && bitDepthValue != 10) {
          _invalid('$path.bitDepth', 'must be 8 or 10');
        }
        final rowMtValue = input['rowMt'];
        if (rowMtValue is! bool) _invalid('$path.rowMt', 'must be a boolean');
        result.add(CompileBundleReportAv1Encoding(
          bitDepth: bitDepthValue == 10 ? 10 : 8,
          cpuUsed: _integer(input['cpuUsed'], '$path.cpuUsed', 0, 8),
          tiles: CompileBundleReportAv1Tiles(columns: columns, rows: rows),
          rowMt: rowMtValue,
          threads: _integer(input['threads'], '$path.threads', 1, 64),
          renditions: renditions,
        ));
      default:
        // `_codecValue` guarantees one of the four codecs above.
        _invalid('$path.codec', 'must be h264, h265, vp9, or av1');
    }
  }
  return List.unmodifiable(result);
}

List<CompileBundleReportRendition> _cloneRenditions(
  Object? value,
  String encodingPath,
  VideoCodec codec,
) {
  final inputs = _boundedArray(value, '$encodingPath.renditions', 1, 4);
  final seen = <String>{};
  final result = <CompileBundleReportRendition>[];
  for (var index = 0; index < inputs.length; index += 1) {
    final path = '$encodingPath.renditions[$index]';
    final input = _record(inputs[index], path);
    _exactKeys(input, const ['id', 'width', 'height', 'crf'], path);
    final id = _stringPattern(
        input['id'], identifierPattern, _identifierText, '$path.id');
    if (seen.contains(id)) _invalid('$path.id', 'must be unique');
    seen.add(id);
    result.add(CompileBundleReportRendition(
      id: id,
      width: _integer(input['width'], '$path.width', 1, 0xffffffff),
      height: _integer(input['height'], '$path.height', 1, 0xffffffff),
      crf: _integer(
        input['crf'],
        '$path.crf',
        0,
        codec == 'vp9' || codec == 'av1' ? 63 : 51,
      ),
    ));
  }
  return List.unmodifiable(result);
}

List<CompileBundleReportInvocation> _cloneInvocations(Object? value) {
  final inputs = _boundedArray(
    value,
    'report.invocations',
    0,
    compileBundleReportLimits.maxInvocations,
  );
  final result = <CompileBundleReportInvocation>[];
  for (var index = 0; index < inputs.length; index += 1) {
    final path = 'report.invocations[$index]';
    final input = _record(inputs[index], path);
    _exactKeys(input, const ['operation', 'tool', 'arguments'], path);
    final argumentInputs = _boundedArray(
      input['arguments'],
      '$path.arguments',
      0,
      compileBundleReportLimits.maxInvocationArguments,
    );
    final arguments = <String>[];
    for (var argumentIndex = 0;
        argumentIndex < argumentInputs.length;
        argumentIndex += 1) {
      arguments.add(_pathFreeText(
        argumentInputs[argumentIndex],
        '$path.arguments[$argumentIndex]',
        compileBundleReportLimits.maxFreeTextCodeUnits,
        true,
      ));
    }
    result.add(CompileBundleReportInvocation(
      operation: _pathFreeText(
        input['operation'],
        '$path.operation',
        compileBundleReportLimits.maxOperationCodeUnits,
      ),
      tool: _oneOf(input['tool'], const ['ffmpeg', 'ffprobe'], '$path.tool'),
      arguments: List.unmodifiable(arguments),
    ));
  }
  return List.unmodifiable(result);
}

CompileBundleReportToolchain _cloneToolchain(Object? value) {
  const path = 'report.toolchain';
  final input = _record(value, path);
  _exactKeys(input, const ['ffmpeg', 'ffprobe', 'aggregateMemoryLimit'], path);
  if (input['aggregateMemoryLimit'] != 'derived') {
    _invalid('$path.aggregateMemoryLimit', 'must be derived');
  }
  return CompileBundleReportToolchain(
    ffmpeg: _cloneFfmpegTool(input['ffmpeg'], '$path.ffmpeg'),
    ffprobe: _cloneFfprobeTool(input['ffprobe'], '$path.ffprobe'),
  );
}

CompileBundleReportFfmpegTool _cloneFfmpegTool(Object? value, String path) {
  final input = _record(value, path);
  _exactKeys(
    input,
    const [
      'executableSha256',
      'executableIdentity',
      'version',
      'versionOutputSha256',
      'configurationSha256',
      'encodersOutputSha256',
      'calibrationSha256',
    ],
    path,
  );
  final base = _cloneToolFields(input, path);
  return CompileBundleReportFfmpegTool(
    executableSha256: base.executableSha256,
    executableIdentity: base.executableIdentity,
    version: base.version,
    versionOutputSha256: base.versionOutputSha256,
    configurationSha256:
        _sha256(input['configurationSha256'], '$path.configurationSha256'),
    encodersOutputSha256:
        _sha256(input['encodersOutputSha256'], '$path.encodersOutputSha256'),
    calibrationSha256:
        _sha256(input['calibrationSha256'], '$path.calibrationSha256'),
  );
}

CompileBundleReportTool _cloneFfprobeTool(Object? value, String path) {
  final input = _record(value, path);
  _exactKeys(
    input,
    const [
      'executableSha256',
      'executableIdentity',
      'version',
      'versionOutputSha256',
    ],
    path,
  );
  return _cloneToolFields(input, path);
}

CompileBundleReportTool _cloneToolFields(
  Map<Object?, Object?> input,
  String path,
) {
  return CompileBundleReportTool(
    executableSha256:
        _sha256(input['executableSha256'], '$path.executableSha256'),
    executableIdentity: _cloneExecutableIdentity(
      input['executableIdentity'],
      '$path.executableIdentity',
    ),
    version: _pathFreeText(
      input['version'],
      '$path.version',
      compileBundleReportLimits.maxFreeTextCodeUnits,
    ),
    versionOutputSha256:
        _sha256(input['versionOutputSha256'], '$path.versionOutputSha256'),
  );
}

CompileBundleReportExecutableIdentity _cloneExecutableIdentity(
  Object? value,
  String path,
) {
  final input = _record(value, path);
  _exactKeys(
    input,
    const ['device', 'inode', 'size', 'mtimeNanoseconds', 'ctimeNanoseconds'],
    path,
  );
  return CompileBundleReportExecutableIdentity(
    device: _decimalTextValue(input['device'], '$path.device'),
    inode: _decimalTextValue(input['inode'], '$path.inode'),
    size: _integer(input['size'], '$path.size', 0, maxSafeInteger),
    mtimeNanoseconds:
        _decimalTextValue(input['mtimeNanoseconds'], '$path.mtimeNanoseconds'),
    ctimeNanoseconds:
        _decimalTextValue(input['ctimeNanoseconds'], '$path.ctimeNanoseconds'),
  );
}

/// Ordered `<source>` markup derived from the validated asset metadata.
String createCompileBundleSourceMarkup(
  List<CompileBundleReportAsset> assets,
) {
  return assets
      .map((asset) =>
          "<source src=\"${asset.path}\" type='${asset.type}' integrity=\"${asset.integrity}\">")
      .join('\n');
}

String _integrityForSha256(String value) {
  final result = StringBuffer();
  for (var offset = 0; offset < value.length; offset += 6) {
    final num byteCount =
        3 < (value.length - offset) / 2 ? 3 : (value.length - offset) / 2;
    final first = int.parse(value.substring(offset, offset + 2), radix: 16);
    final second = byteCount > 1
        ? int.parse(value.substring(offset + 2, offset + 4), radix: 16)
        : 0;
    final third = byteCount > 2
        ? int.parse(value.substring(offset + 4, offset + 6), radix: 16)
        : 0;
    final group = (first << 16) | (second << 8) | third;
    result.write(_base64Alphabet[(group >>> 18) & 0x3f]);
    result.write(_base64Alphabet[(group >>> 12) & 0x3f]);
    result.write(byteCount > 1 ? _base64Alphabet[(group >>> 6) & 0x3f] : '=');
    result.write(byteCount > 2 ? _base64Alphabet[group & 0x3f] : '=');
  }
  return 'sha256-$result';
}

VideoCodec _codecValue(Object? value, String path) {
  if (value is! String || !videoCodecs.contains(value)) {
    _invalid(path, 'must be h264, h265, vp9, or av1');
  }
  return value;
}

String _sha256(Object? value, String path) =>
    _stringPattern(value, sha256HexPattern, _sha256Text, path);

String _decimalTextValue(Object? value, String path) =>
    _stringPattern(value, _decimalText, _decimalTextText, path);

int _powerOfTwo(Object? value, String path) {
  final result = _integer(value, path, 1, 64);
  if ((result & (result - 1)) != 0) _invalid(path, 'must be a power of two');
  return result;
}

int _integer(Object? value, String path, int minimum, int maximum) {
  if (value is! int || value < minimum || value > maximum) {
    _invalid(path, 'must be an integer from $minimum to $maximum');
  }
  return value;
}

String _boundedString(
  Object? value,
  String path,
  int maximum, [
  bool allowEmpty = false,
]) {
  if (value is! String ||
      (!allowEmpty && value.isEmpty) ||
      value.length > maximum ||
      _controlCharacter.hasMatch(value)) {
    _invalid(
      path,
      'must be ${allowEmpty ? 'a' : 'a non-empty'} string of at most $maximum characters without control characters',
    );
  }
  return value;
}

String _pathFreeText(
  Object? value,
  String path,
  int maximum, [
  bool allowEmpty = false,
]) {
  final result = _boundedString(value, path, maximum, allowEmpty);
  if (_pathOrUrl.hasMatch(result)) {
    _invalid(path, 'must not contain a local path or URL');
  }
  return result;
}

String _stringPattern(
  Object? value,
  RegExp pattern,
  String patternText,
  String path,
) {
  if (value is! String || !pattern.hasMatch(value)) {
    _invalid(path, 'must match $patternText');
  }
  return value;
}

String _oneOf(Object? value, List<String> choices, String path) {
  if (value is! String || !choices.contains(value)) {
    _invalid(path, 'must be one of ${choices.join(', ')}');
  }
  return value;
}

List<Object?> _boundedArray(
  Object? value,
  String path,
  int minimum,
  int maximum,
) {
  final result = _denseArray(value, path);
  if (result.length < minimum || result.length > maximum) {
    _invalid(path, 'must contain $minimum through $maximum entries');
  }
  return result;
}

List<Object?> _denseArray(Object? value, String path) {
  // Dart lists are never sparse, so the TS `hasOwnProperty` per-index guard has
  // no analogue and is intentionally omitted.
  if (value is! List<Object?>) _invalid(path, 'must be an array');
  return value;
}

Map<Object?, Object?> _record(Object? value, String path) {
  if (value is! Map<Object?, Object?>) _invalid(path, 'must be an object');
  return value;
}

void _exactKeys(
  Map<Object?, Object?> value,
  List<String> keys,
  String path,
) {
  final expected = keys.toSet();
  for (final key in value.keys) {
    if (key is! String || !expected.contains(key)) {
      _invalid(path, 'contains an unknown field $key');
    }
  }
  for (final key in keys) {
    if (!value.containsKey(key)) {
      _invalid('$path.$key', 'is required');
    }
  }
}

// Plain JSON tree used only for the canonical-serialization size guard. The
// return value is discarded; only a thrown limit violation is meaningful.
Map<String, Object?> _reportToCanonicalValue(ParsedCompileBundleReport report) {
  return {
    'reportVersion': report.reportVersion,
    'assets': [
      for (final a in report.assets)
        {
          'codec': a.codec,
          'path': a.path,
          'bytes': a.bytes,
          'sha256': a.sha256,
          'codecString': a.codecString,
          'type': a.type,
          'integrity': a.integrity,
        },
    ],
    'encodings': [
      for (final e in report.encodings) _encodingToCanonicalValue(e),
    ],
    'invocations': [
      for (final i in report.invocations)
        {
          'operation': i.operation,
          'tool': i.tool,
          'arguments': [...i.arguments],
        },
    ],
    'warnings': [...report.warnings],
    'toolchain': {
      'ffmpeg': _ffmpegToolToCanonicalValue(report.toolchain.ffmpeg),
      'ffprobe': _toolToCanonicalValue(report.toolchain.ffprobe),
      'aggregateMemoryLimit': report.toolchain.aggregateMemoryLimit,
    },
    'sourceMarkup': report.sourceMarkup,
  };
}

Map<String, Object?> _encodingToCanonicalValue(
  CompileBundleReportEncoding encoding,
) {
  final renditions = [
    for (final r in encoding.renditions)
      {'id': r.id, 'width': r.width, 'height': r.height, 'crf': r.crf},
  ];
  switch (encoding) {
    case CompileBundleReportH264Encoding():
      return {
        'codec': encoding.codec,
        'preset': encoding.preset,
        'renditions': renditions,
      };
    case CompileBundleReportH265Encoding():
      return {
        'codec': encoding.codec,
        'preset': encoding.preset,
        'threads': encoding.threads,
        'renditions': renditions,
      };
    case CompileBundleReportVp9Encoding():
      return {
        'codec': encoding.codec,
        'deadline': encoding.deadline,
        'cpuUsed': encoding.cpuUsed,
        'threads': encoding.threads,
        'renditions': renditions,
      };
    case CompileBundleReportAv1Encoding():
      return {
        'codec': encoding.codec,
        'bitDepth': encoding.bitDepth,
        'cpuUsed': encoding.cpuUsed,
        'tiles': {
          'columns': encoding.tiles.columns,
          'rows': encoding.tiles.rows,
        },
        'rowMt': encoding.rowMt,
        'threads': encoding.threads,
        'renditions': renditions,
      };
  }
}

Map<String, Object?> _toolToCanonicalValue(CompileBundleReportTool tool) => {
      'executableSha256': tool.executableSha256,
      'executableIdentity': {
        'device': tool.executableIdentity.device,
        'inode': tool.executableIdentity.inode,
        'size': tool.executableIdentity.size,
        'mtimeNanoseconds': tool.executableIdentity.mtimeNanoseconds,
        'ctimeNanoseconds': tool.executableIdentity.ctimeNanoseconds,
      },
      'version': tool.version,
      'versionOutputSha256': tool.versionOutputSha256,
    };

Map<String, Object?> _ffmpegToolToCanonicalValue(
  CompileBundleReportFfmpegTool tool,
) =>
    {
      ..._toolToCanonicalValue(tool),
      'configurationSha256': tool.configurationSha256,
      'encodersOutputSha256': tool.encodersOutputSha256,
      'calibrationSha256': tool.calibrationSha256,
    };

Never _invalid(String path, String message) {
  throw FormatException('compile bundle report: $path $message');
}
