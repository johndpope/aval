// Dart port of `packages/format/test/video-geometry.test.ts`.
import 'package:aval_format/src/errors.dart';
import 'package:aval_format/src/model.dart' show Rect;
import 'package:aval_format/src/video/geometry.dart';
import 'package:aval_format/src/video/model.dart';
import 'package:test/test.dart';

void main() {
  group('deriveVideoRenditionGeometry', () {
    test('derives opaque geometry using codec-owned storage alignment', () {
      final result = deriveVideoRenditionGeometry(
        const VideoRenditionGeometryInput(
          canvasWidth: 15,
          canvasHeight: 17,
          layout: 'opaque',
          visibleWidth: 15,
          visibleHeight: 17,
          storage: VideoStoragePolicy(widthAlignment: 16, heightAlignment: 16),
        ),
      );
      expect(result.layout, 'opaque');
      expect(result.visibleColorRect, const Rect(0, 0, 15, 17));
      expect(result.visibleAlphaRect, isNull);
      expect(result.decodedStorageRect, const Rect(0, 0, 16, 18));
      expect(result.codedWidth, 16);
      expect(result.codedHeight, 32);
      expect(result.visibleColorArea, 255);
      expect(result.decodedRgbaBytes, 16 * 18 * 4);
      expect(result.codedRgbaBytes, 16 * 32 * 4);
    });

    test('uses one shared packed-alpha layout for every codec', () {
      final result = deriveVideoRenditionGeometry(
        const VideoRenditionGeometryInput(
          canvasWidth: 15,
          canvasHeight: 17,
          layout: 'packed-alpha',
          visibleWidth: 15,
          visibleHeight: 17,
          storage: VideoStoragePolicy(widthAlignment: 2, heightAlignment: 2),
        ),
      );
      expect(result.layout, 'packed-alpha');
      expect(result.visibleColorRect, const Rect(0, 0, 15, 17));
      expect(result.visibleAlphaRect, Rect(0, 18 + packedAlphaGutter, 15, 17));
      expect(result.decodedStorageRect, const Rect(0, 0, 16, 44));
      expect(result.codedWidth, 16);
      expect(result.codedHeight, 44);
      expect(result.visibleColorArea, 255);
      expect(result.decodedRgbaBytes, 16 * 44 * 4);
      expect(result.codedRgbaBytes, 16 * 44 * 4);
    });

    test('rejects aspect drift, canvas overflow, invalid policy, and unsafe products',
        () {
      const maxSafeInteger = 9007199254740991;
      final inputs = <VideoRenditionGeometryInput>[
        const VideoRenditionGeometryInput(
          canvasWidth: 16,
          canvasHeight: 9,
          layout: 'opaque',
          visibleWidth: 15,
          visibleHeight: 9,
          storage: VideoStoragePolicy(widthAlignment: 2, heightAlignment: 2),
        ),
        const VideoRenditionGeometryInput(
          canvasWidth: 16,
          canvasHeight: 9,
          layout: 'opaque',
          visibleWidth: 17,
          visibleHeight: 9,
          storage: VideoStoragePolicy(widthAlignment: 2, heightAlignment: 2),
        ),
        const VideoRenditionGeometryInput(
          canvasWidth: 16,
          canvasHeight: 9,
          layout: 'opaque',
          visibleWidth: 16,
          visibleHeight: 9,
          storage: VideoStoragePolicy(widthAlignment: 0, heightAlignment: 2),
        ),
        const VideoRenditionGeometryInput(
          canvasWidth: maxSafeInteger,
          canvasHeight: 9,
          layout: 'opaque',
          visibleWidth: 16,
          visibleHeight: 9,
          storage: VideoStoragePolicy(widthAlignment: 2, heightAlignment: 2),
        ),
      ];
      for (final input in inputs) {
        expect(() => deriveVideoRenditionGeometry(input), throwsA(isA<FormatError>()));
      }
    });
  });
}
