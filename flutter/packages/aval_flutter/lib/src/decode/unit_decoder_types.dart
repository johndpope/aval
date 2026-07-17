/// Platform-neutral types for the per-unit frame decoder.
///
/// `rabbit_controller.dart` assembles [EncodedUnitChunk]s from the parsed
/// `.avl` records and hands them to an [AvalUnitDecoder]; the implementation
/// is chosen by conditional import in `unit_decoder.dart` (Rust FFI on
/// native, WebCodecs on web).
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

/// One format-1.0 encoded chunk (Annex-B access unit) of a unit.
class EncodedUnitChunk {
  EncodedUnitChunk({
    required this.data,
    required this.presentationTimestamp,
    required this.duration,
    required this.randomAccess,
    required this.displayedFrameCount,
  });

  /// Annex-B bytes (a view into the asset buffer — do not mutate).
  final Uint8List data;
  final int presentationTimestamp;
  final int duration;
  final bool randomAccess;
  final int displayedFrameCount;
}

/// Decodes one unit's chunks into presentation-ordered RGBA [ui.Image]s.
abstract interface class AvalUnitDecoder {
  Future<List<ui.Image>> decodeUnit({
    required String unitId,
    required int unitFrameCount,
    required int codedWidth,
    required int codedHeight,
    required String codecString,
    required List<EncodedUnitChunk> chunks,
  });

  /// Human-readable description of the decode backend (for error views).
  String get description;
}
