/// Dart port of `packages/format/test/avc-rendition-geometry.test.ts`.
library;

import 'package:aval_format/src/avc/index.dart';
import 'package:aval_format/src/errors.dart';
import 'package:aval_format/src/model.dart' show Rect;
import 'package:test/test.dart';

const int _maxSafeInteger = 9007199254740991;
const List<int> _dimensions = [1, 2, 15, 16, 511, 512];

void main() {
  group('deriveAvcRenditionGeometry', () {
    test('maps each exact production profile to its versioned quantization policy', () {
      expect(
        avcQuantizationPolicyForRendition('avc-annexb-opaque-v0'),
        'fixed-qp26-v0',
      );
      expect(
        avcQuantizationPolicyForRendition('avc-annexb-packed-alpha-v0'),
        'fixed-qp26-v0',
      );
      expect(
        avcQuantizationPolicyForRendition('avc-annexb-opaque-v1'),
        'bounded-qp-v1',
      );
      expect(
        avcQuantizationPolicyForRendition('avc-annexb-packed-alpha-v1'),
        'bounded-qp-v1',
      );
      _expectProfileInvalid(
        () => avcQuantizationPolicyForRendition('avc-annexb-opaque-v2'),
        'rendition.profile',
      );
    });

    test('derives v1 geometry without changing the opaque or packed layout', () {
      final opaqueGeometry = deriveAvcRenditionGeometryFromVisible(
        const AvcVisibleRenditionGeometryInput(
          canvasWidth: 16,
          canvasHeight: 16,
          profile: 'avc-annexb-opaque-v1',
          visibleWidth: 16,
          visibleHeight: 16,
        ),
      );
      expect(opaqueGeometry.profile, 'avc-annexb-opaque-v1');
      expect(opaqueGeometry.decodedStorageRect, Rect(0, 0, 16, 16));

      final packedGeometry = deriveAvcRenditionGeometryFromVisible(
        const AvcVisibleRenditionGeometryInput(
          canvasWidth: 16,
          canvasHeight: 16,
          profile: 'avc-annexb-packed-alpha-v1',
          visibleWidth: 16,
          visibleHeight: 16,
        ),
      );
      expect(packedGeometry.profile, 'avc-annexb-packed-alpha-v1');
      expect(packedGeometry.visibleAlphaRect, Rect(0, 24, 16, 16));
      expect(packedGeometry.decodedStorageRect, Rect(0, 0, 16, 40));
    });

    test('preserves authored visible geometry above the former canvas ceiling', () {
      final geometry = deriveAvcRenditionGeometryFromVisible(
        const AvcVisibleRenditionGeometryInput(
          canvasWidth: 1024,
          canvasHeight: 576,
          profile: 'avc-annexb-opaque-v0',
          visibleWidth: 1024,
          visibleHeight: 576,
        ),
      );
      expect(geometry.visibleColorRect, Rect(0, 0, 1024, 576));
      expect(geometry.codedWidth, 1024);
      expect(geometry.codedHeight, 576);
      expect(geometry.decodedRgbaBytes, 1024 * 576 * 4);
    });

    test('derives compiler-ready manifest facts from visible dimensions alone', () {
      final geometry = deriveAvcRenditionGeometryFromVisible(
        const AvcVisibleRenditionGeometryInput(
          canvasWidth: 15,
          canvasHeight: 17,
          profile: 'avc-annexb-packed-alpha-v0',
          visibleWidth: 15,
          visibleHeight: 17,
        ),
      );
      expect(geometry.profile, 'avc-annexb-packed-alpha-v0');
      expect(geometry.visibleColorRect, Rect(0, 0, 15, 17));
      expect(geometry.visibleAlphaRect, Rect(0, 26, 15, 17));
      expect(geometry.decodedStorageRect, Rect(0, 0, 16, 44));
      expect(geometry.codedWidth, 16);
      expect(geometry.codedHeight, 48);
      expect(geometry.visibleColorArea, 255);
      expect(geometry.decodedRgbaBytes, 2816);
      expect(geometry.codedRgbaBytes, 3072);
    });

    test('derives every odd/even opaque geometry combination exactly', () {
      for (final width in _dimensions) {
        for (final height in _dimensions) {
          final paneWidth = _even(width);
          final paneHeight = _even(height);
          final codedWidth = _align16(paneWidth);
          final codedHeight = _align16(paneHeight);
          final geometry = deriveAvcRenditionGeometry(_opaqueInput(width, height));

          expect(geometry.profile, 'avc-annexb-opaque-v0');
          expect(geometry.visibleColorRect, Rect(0, 0, width, height));
          expect(geometry.visibleAlphaRect, isNull);
          expect(geometry.decodedStorageRect, Rect(0, 0, paneWidth, paneHeight));
          expect(geometry.codedWidth, codedWidth);
          expect(geometry.codedHeight, codedHeight);
          expect(geometry.visibleColorArea, width * height);
          expect(geometry.decodedRgbaBytes, paneWidth * paneHeight * 4);
          expect(geometry.codedRgbaBytes, codedWidth * codedHeight * 4);
          // NOTE: the TS source also asserts `Object.isFrozen` deeply here.
          // Dart has no runtime-freeze equivalent; immutability is instead
          // guaranteed by construction (final fields on AvcRenditionGeometry
          // and its Rect members), so that assertion is intentionally
          // dropped.
        }
      }
    });

    test('derives every odd/even packed geometry combination with one fixed gutter', () {
      for (final width in _dimensions) {
        for (final height in _dimensions) {
          final paneWidth = _even(width);
          final paneHeight = _even(height);
          final storageHeight = 2 * paneHeight + 8;
          final codedWidth = _align16(paneWidth);
          final codedHeight = _align16(storageHeight);
          final geometry = deriveAvcRenditionGeometry(_packedInput(width, height));

          expect(geometry.profile, 'avc-annexb-packed-alpha-v0');
          expect(geometry.visibleColorRect, Rect(0, 0, width, height));
          expect(
            geometry.visibleAlphaRect,
            Rect(0, paneHeight + 8, width, height),
          );
          expect(
            geometry.decodedStorageRect,
            Rect(0, 0, paneWidth, storageHeight),
          );
          expect(geometry.codedWidth, codedWidth);
          expect(geometry.codedHeight, codedHeight);
          expect(geometry.visibleColorArea, width * height);
          expect(geometry.decodedRgbaBytes, paneWidth * storageHeight * 4);
          expect(geometry.codedRgbaBytes, codedWidth * codedHeight * 4);
        }
      }
    });

    test('requires the source pixel-grid aspect and canvas bounds exactly', () {
      final base = _opaqueInput(16, 16);
      _expectProfileInvalid(
        () => deriveAvcRenditionGeometry(
          _variant(base, canvasWidth: 32, canvasHeight: 16),
        ),
        'rendition.alphaLayout.colorRect',
      );
      _expectProfileInvalid(
        () => deriveAvcRenditionGeometry(_variant(base, canvasWidth: 15)),
        'rendition.alphaLayout.colorRect',
      );
    });

    test('rejects every alternate packed origin, pane size, gap, overlap, or coded size', () {
      final valid = _packedInput(15, 17);
      final invalid = <AvcRenditionGeometryInput>[
        _packedVariant(valid, colorRect: Rect(1, 0, 15, 17)),
        _packedVariant(valid, colorRect: Rect(0, 1, 15, 17)),
        _packedVariant(valid, colorRect: Rect(0, 0, 14, 17)),
        _packedVariant(valid, alphaRect: Rect(1, 26, 15, 17)),
        _packedVariant(valid, alphaRect: Rect(0, 26, 14, 17)),
        _packedVariant(valid, alphaRect: Rect(0, 25, 15, 17)),
        _packedVariant(valid, alphaRect: Rect(0, 27, 15, 17)),
        _packedVariant(valid, codedWidth: 15),
        _packedVariant(valid, codedWidth: 32),
        _packedVariant(valid, codedHeight: 47),
        _packedVariant(valid, codedHeight: 64),
      ];

      for (final input in invalid) {
        _expectProfileInvalid(() => deriveAvcRenditionGeometry(input));
      }
    });

    test('rejects alternate opaque storage padding and profile-incompatible alpha facts', () {
      final valid = _opaqueInput(15, 17);
      _expectProfileInvalid(
        () => deriveAvcRenditionGeometry(_variant(valid, codedWidth: 32)),
      );
      _expectProfileInvalid(
        () => deriveAvcRenditionGeometry(
          AvcRenditionGeometryInput(
            canvasWidth: valid.canvasWidth,
            canvasHeight: valid.canvasHeight,
            codedWidth: valid.codedWidth,
            codedHeight: valid.codedHeight,
            colorRect: valid.colorRect,
            profile: valid.profile,
            alphaRect: Rect(0, 26, 15, 17),
            hasAlphaRectField: true,
          ),
        ),
      );
      final validPacked = _packedInput(15, 17);
      _expectProfileInvalid(
        () => deriveAvcRenditionGeometry(
          AvcRenditionGeometryInput(
            canvasWidth: validPacked.canvasWidth,
            canvasHeight: validPacked.canvasHeight,
            codedWidth: validPacked.codedWidth,
            codedHeight: validPacked.codedHeight,
            colorRect: validPacked.colorRect,
            profile: validPacked.profile,
          ),
        ),
      );
    });

    test('rejects unsafe and over-limit dimensions and products before deriving', () {
      final base = _opaqueInput(1, 1);
      final inputs = <AvcRenditionGeometryInput>[
        _variant(base, canvasWidth: _maxSafeInteger),
        _variant(base, codedWidth: _maxSafeInteger),
        _variant(base, codedWidth: 2048, codedHeight: 2048),
        _variant(base, codedWidth: 2048),
        _variant(base, codedHeight: 2048),
        _variant(base, colorRect: Rect(0, 0, _maxSafeInteger, 1)),
      ];
      for (final input in inputs) {
        _expectProfileInvalid(() => deriveAvcRenditionGeometry(input));
      }
    });
  });
}

AvcRenditionGeometryInput _opaqueInput(int width, int height) {
  return AvcRenditionGeometryInput(
    canvasWidth: width,
    canvasHeight: height,
    profile: 'avc-annexb-opaque-v0',
    codedWidth: _align16(_even(width)),
    codedHeight: _align16(_even(height)),
    colorRect: Rect(0, 0, width, height),
  );
}

AvcRenditionGeometryInput _packedInput(int width, int height) {
  final paneWidth = _even(width);
  final paneHeight = _even(height);
  return AvcRenditionGeometryInput(
    canvasWidth: width,
    canvasHeight: height,
    profile: 'avc-annexb-packed-alpha-v0',
    codedWidth: _align16(paneWidth),
    codedHeight: _align16(2 * paneHeight + 8),
    colorRect: Rect(0, 0, width, height),
    alphaRect: Rect(0, paneHeight + 8, width, height),
    hasAlphaRectField: true,
  );
}

AvcRenditionGeometryInput _variant(
  AvcRenditionGeometryInput base, {
  int? canvasWidth,
  int? canvasHeight,
  int? codedWidth,
  int? codedHeight,
  Rect? colorRect,
}) {
  return AvcRenditionGeometryInput(
    canvasWidth: canvasWidth ?? base.canvasWidth,
    canvasHeight: canvasHeight ?? base.canvasHeight,
    codedWidth: codedWidth ?? base.codedWidth,
    codedHeight: codedHeight ?? base.codedHeight,
    colorRect: colorRect ?? base.colorRect,
    profile: base.profile,
  );
}

AvcRenditionGeometryInput _packedVariant(
  AvcRenditionGeometryInput base, {
  Rect? colorRect,
  Rect? alphaRect,
  int? codedWidth,
  int? codedHeight,
}) {
  return AvcRenditionGeometryInput(
    canvasWidth: base.canvasWidth,
    canvasHeight: base.canvasHeight,
    codedWidth: codedWidth ?? base.codedWidth,
    codedHeight: codedHeight ?? base.codedHeight,
    colorRect: colorRect ?? base.colorRect,
    profile: base.profile,
    alphaRect: alphaRect ?? base.alphaRect,
    hasAlphaRectField: true,
  );
}

int _even(int value) => value % 2 == 0 ? value : value + 1;

int _align16(int value) => ((value + 15) ~/ 16) * 16;

FormatError _expectProfileInvalid(void Function() action, [String? path]) {
  try {
    action();
  } on FormatError catch (error) {
    expect(error.code, FormatErrorCode.profileInvalid);
    if (path != null) {
      expect(error.path, path);
    }
    return error;
  }
  fail('expected PROFILE_INVALID');
}
