/// Declared runtime/compiled-byte limits schema validation.
///
/// Dart port of `packages/format/src/manifest-limits-schema.ts`.
library;

import 'avc/rendition_geometry.dart' show AvcRenditionGeometryInput, deriveAvcRenditionGeometryAtPath;
import 'checked_integer.dart' show checkedMultiply;
import 'manifest_validation.dart';
import 'model.dart';

const int _maxSafeInteger = 9007199254740991;

DeclaredLimitsV01 cloneDeclaredLimits(
  Object? value,
  List<RenditionV01> renditions,
  CanvasV01 canvas,
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
  final maxCompiledBytes =
      positiveInteger(input['maxCompiledBytes'], '$path.maxCompiledBytes', budgets.maxFileBytes);
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
    int candidate;
    if (rendition.profile == 'reference-rgba-v0') {
      candidate = checkedMultiply(
        checkedMultiply(
          rendition.codedWidth,
          rendition.codedHeight,
          _maxSafeInteger,
          'renditions[$index] decoded pixel count',
        ),
        4,
        _maxSafeInteger,
        'renditions[$index] decoded RGBA bytes',
      );
    } else {
      final Rect colorRect;
      final Rect? alphaRect;
      if (rendition is AvcPackedAlphaRenditionV01) {
        colorRect = rendition.colorRect;
        alphaRect = rendition.alphaRect;
      } else {
        colorRect = (rendition as AvcOpaqueRenditionV01).colorRect;
        alphaRect = null;
      }
      candidate = deriveAvcRenditionGeometryAtPath(
        AvcRenditionGeometryInput(
          canvasWidth: canvas.width,
          canvasHeight: canvas.height,
          codedWidth: rendition.codedWidth,
          codedHeight: rendition.codedHeight,
          colorRect: colorRect,
          profile: rendition.profile,
          alphaRect: alphaRect,
          hasAlphaRectField: alphaRect != null,
        ),
        'renditions[$index]',
      ).codedRgbaBytes;
    }
    if (candidate > minimumDecodedBytes) minimumDecodedBytes = candidate;
  }
  if (decodedPixelBytes < minimumDecodedBytes) {
    invalid('$path.decodedPixelBytes', 'must be at least $minimumDecodedBytes');
  }
  return DeclaredLimitsV01(
    maxCompiledBytes: maxCompiledBytes,
    maxRuntimeBytes: maxRuntimeBytes,
    decodedPixelBytes: decodedPixelBytes,
    persistentCacheBytes: persistentCacheBytes,
    runtimeWorkingSetBytes: runtimeWorkingSetBytes,
  );
}
