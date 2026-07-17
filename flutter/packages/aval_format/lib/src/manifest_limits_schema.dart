/// Declared runtime/compiled-byte limits schema validation.
///
/// Dart port of `packages/format/src/manifest-limits-schema.ts` (1.0). The
/// minimum decoded-pixel budget is derived directly from each rendition's
/// coded surface (`codedWidth * codedHeight * 4`).
library;

import 'checked_integer.dart' show checkedMultiply;
import 'errors.dart';
import 'manifest_validation.dart';
import 'model.dart';

const int _maxSafeInteger = 9007199254740991;

DeclaredLimits cloneDeclaredLimits(
  Object? value,
  List<ProductionRendition> renditions,
  FormatBudgets budgets,
  String path,
) {
  final input = record(value, path);
  exactKeys(
    input,
    [
      'maxCompiledBytes',
      'maxRuntimeBytes',
      'decodedPixelBytes',
      'persistentCacheBytes',
      'runtimeWorkingSetBytes',
    ],
    path,
  );
  final maxCompiledBytes = positiveInteger(input['maxCompiledBytes'], '$path.maxCompiledBytes');
  if (maxCompiledBytes > budgets.maxFileBytes) {
    throw FormatError(
      FormatErrorCode.budgetExceeded,
      'maxCompiledBytes exceeds the active limit of ${budgets.maxFileBytes}',
      FormatErrorDetails(path: '$path.maxCompiledBytes'),
    );
  }
  final maxRuntimeBytes = positiveInteger(input['maxRuntimeBytes'], '$path.maxRuntimeBytes');
  final decodedPixelBytes =
      integerInRange(input['decodedPixelBytes'], '$path.decodedPixelBytes', 0, maxRuntimeBytes);
  final persistentCacheBytes =
      integerInRange(input['persistentCacheBytes'], '$path.persistentCacheBytes', 0, maxRuntimeBytes);
  final runtimeWorkingSetBytes = integerInRange(
    input['runtimeWorkingSetBytes'],
    '$path.runtimeWorkingSetBytes',
    0,
    maxRuntimeBytes,
  );
  if (runtimeWorkingSetBytes < decodedPixelBytes || runtimeWorkingSetBytes < persistentCacheBytes) {
    invalid(
      '$path.runtimeWorkingSetBytes',
      'must be at least decodedPixelBytes and persistentCacheBytes',
    );
  }
  var minimumDecodedBytes = 0;
  for (var index = 0; index < renditions.length; index += 1) {
    final rendition = renditions[index];
    final candidate = checkedMultiply(
      checkedMultiply(
        rendition.codedWidth,
        rendition.codedHeight,
        _maxSafeInteger,
        'renditions[$index] coded pixel count',
      ),
      4,
      _maxSafeInteger,
      'renditions[$index] decoded RGBA bytes',
    );
    if (candidate > minimumDecodedBytes) minimumDecodedBytes = candidate;
  }
  if (decodedPixelBytes < minimumDecodedBytes) {
    invalid('$path.decodedPixelBytes', 'must be at least $minimumDecodedBytes');
  }
  return DeclaredLimits(
    maxCompiledBytes: maxCompiledBytes,
    maxRuntimeBytes: maxRuntimeBytes,
    decodedPixelBytes: decodedPixelBytes,
    persistentCacheBytes: persistentCacheBytes,
    runtimeWorkingSetBytes: runtimeWorkingSetBytes,
  );
}
