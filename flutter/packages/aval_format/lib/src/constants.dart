/// Wire constants and budget resolution for the version-1.0 AVAL format.
///
/// Dart port of `packages/format/src/constants.ts`.
library;

import 'errors.dart';
import 'model.dart' show FormatBudgets, FormatOptions;

const List<int> formatMagic = [0x41, 0x56, 0x4c, 0x46, 0x0d, 0x0a, 0x1a, 0x0a];
const List<int> chunkIndexMagic = [0x41, 0x56, 0x4c, 0x49];

const int formatVersionMajor = 1;
const int formatVersionMinor = 0;
const int formatHeaderLength = 64;
const int formatAlignment = 8;
const int chunkIndexHeaderLength = 16;
const int chunkIndexRecordLength = 48;
const int _uint32Max = 0xffffffff;

final RegExp identifierPattern = RegExp(r'^[a-z][a-z0-9._-]{0,63}$');
final RegExp sha256HexPattern = RegExp(r'^[0-9a-f]{64}$');

const int _maxSafeInteger = 9007199254740991;

final FormatBudgets formatDefaultBudgets = FormatBudgets(
  maxFileBytes: _maxSafeInteger,
  maxManifestBytes: 1024 * 1024,
  maxIndexBytes: _maxSafeInteger,
  maxChunkBytes: _uint32Max,
  maxPngBytes: _maxSafeInteger,
  maxJsonDepth: 64,
  maxJsonNodes: 20000,
  maxJsonStringBytes: 4096,
  maxStates: 32,
  maxEdges: 64,
  maxUnits: 96,
  maxRenditions: 4,
  maxBindings: 32,
  maxBlobRanges: 128,
  maxTotalUnitFrames: _uint32Max,
  maxChunkRecords: _uint32Max,
  maxPortsPerBody: 16,
  maxReversibleFrames: _uint32Max,
);

const List<String> _budgetKeys = [
  'maxFileBytes',
  'maxManifestBytes',
  'maxIndexBytes',
  'maxChunkBytes',
  'maxPngBytes',
  'maxJsonDepth',
  'maxJsonNodes',
  'maxJsonStringBytes',
  'maxStates',
  'maxEdges',
  'maxUnits',
  'maxRenditions',
  'maxBindings',
  'maxBlobRanges',
  'maxTotalUnitFrames',
  'maxChunkRecords',
  'maxPortsPerBody',
  'maxReversibleFrames',
];
final Set<String> _budgetKeySet = _budgetKeys.toSet();

/// Resolves lower-only caller overrides into a fresh immutable budget set.
FormatBudgets resolveFormatBudgets([FormatOptions? options]) {
  try {
    if (options == null) {
      return formatDefaultBudgets;
    }

    final overrides = options.budgets;
    if (overrides == null) {
      return formatDefaultBudgets;
    }

    for (final key in overrides.keys) {
      if (!_budgetKeySet.contains(key)) {
        throw FormatError(
          FormatErrorCode.inputInvalid,
          'unknown format budget $key',
          FormatErrorDetails(path: 'budgets.$key'),
        );
      }
    }

    final resolvedMap = formatDefaultBudgets.toMap();
    for (final key in _budgetKeys) {
      if (!overrides.containsKey(key)) continue;
      final override = overrides[key];
      final defaultValue = resolvedMap[key]!;
      if (override == null || override < 0 || override > defaultValue) {
        throw FormatError(
          FormatErrorCode.inputInvalid,
          '$key must be a nonnegative safe integer no greater than $defaultValue',
          FormatErrorDetails(path: 'budgets.$key'),
        );
      }
      resolvedMap[key] = override;
    }

    return FormatBudgets.fromMap(resolvedMap);
  } on FormatError {
    rethrow;
  } catch (_) {
    throw FormatError(
      FormatErrorCode.inputInvalid,
      'format options could not be read',
    );
  }
}
