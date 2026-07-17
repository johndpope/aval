/// Native [AvalUnitDecoder]: the `aval_decode` Rust core via `dart:ffi`.
///
/// This is the decode loop that used to live inline in
/// `rabbit_controller.dart` (`_decodeUnit`), moved behind the platform
/// interface so the web build can substitute WebCodecs.
library;

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../ffi/aval_ffi.dart';
import 'unit_decoder_types.dart';

/// Resolved path to the aval_decode shared library. Set by
/// `--dart-define=AVAL_DECODE_LIB=<abs path>` (see scripts/run.sh); otherwise
/// falls back to the default cargo release artifact relative to the example
/// dir.
///
/// On iOS the crate is statically linked into the Runner binary (see
/// `ios/Flutter/*AvalDecode.xcconfig`); `avalDecodeUseProcess` is true and the
/// path is unused.
const String _libDefine = String.fromEnvironment('AVAL_DECODE_LIB');
const bool avalDecodeUseProcess =
    bool.fromEnvironment('AVAL_DECODE_USE_PROCESS', defaultValue: false);
const String _libFallback =
    '../../rust/aval_decode/target/release/libaval_decode.dylib';

String get avalDecodeLibPath =>
    _libDefine.isNotEmpty ? _libDefine : _libFallback;

/// Opens the native decoder: process lookup on iOS (static link), else dylib
/// path.
AvalDecodeBindings openAvalDecodeBindings() {
  if (avalDecodeUseProcess || Platform.isIOS) {
    debugPrint('[rabbit] opening aval_decode via DynamicLibrary.process()');
    return AvalDecodeBindings.openProcess();
  }
  debugPrint('[rabbit] opening dylib: $avalDecodeLibPath');
  return AvalDecodeBindings.open(avalDecodeLibPath);
}

AvalUnitDecoder createUnitDecoder() => FfiUnitDecoder();

/// Backend description surfaced in the error view (`main.dart`).
String get unitDecoderDescription => 'aval_decode FFI ($avalDecodeLibPath)';

class FfiUnitDecoder implements AvalUnitDecoder {
  AvalDecodeBindings? _bindings;

  AvalDecodeBindings get bindings => _bindings ??= openAvalDecodeBindings();

  @override
  String get description => unitDecoderDescription;

  @override
  Future<List<ui.Image>> decodeUnit({
    required String unitId,
    required int unitFrameCount,
    required int codedWidth,
    required int codedHeight,
    required String codecString,
    required List<EncodedUnitChunk> chunks,
  }) async {
    // Slot frames by presentation index so B-frame decode order still paints
    // in display order.
    final byPresentation = <int, ui.Image>{};
    final session = AvalDecoderSession.create(bindings);
    try {
      session.configure(codedWidth: codedWidth, codedHeight: codedHeight);
      session.activateGeneration(1);
      for (var i = 0; i < chunks.length; i++) {
        final chunk = chunks[i];
        final presentationIndex = chunk.presentationTimestamp;
        final frameId = session.submit(
          decodeIndex: i,
          unitChunkCount: chunks.length,
          unitFrameCount: unitFrameCount,
          presentationTimestamp: presentationIndex,
          duration: chunk.duration,
          randomAccess: chunk.randomAccess,
          data: chunk.data,
          unitId: unitId,
          presentationIndices: <int>[presentationIndex],
          presentationOrdinalBase: 0,
          displayedFrameCount: chunk.displayedFrameCount,
        );
        if (frameId == null) continue;
        final image = session.takeFrame<Future<ui.Image>>(
          (view) => _rgbaToImage(
            Uint8List.fromList(view.rgba),
            view.width,
            view.height,
          ),
        );
        if (image == null) continue;
        final img = await image;
        // Prefer the decoder's unit_frame when available; fall back to PTS.
        byPresentation[presentationIndex] = img;
      }
      // Drain any frames still queued after the last submit (B-frame tail).
      while (true) {
        final image = session.takeFrame<Future<ui.Image>>(
          (view) => _rgbaToImage(
            Uint8List.fromList(view.rgba),
            view.width,
            view.height,
          ),
        );
        if (image == null) break;
        final img = await image;
        // Without a presentation index on take, append at next free slot.
        var slot = byPresentation.length;
        while (byPresentation.containsKey(slot)) {
          slot++;
        }
        byPresentation[slot] = img;
      }
    } finally {
      session.disposeSession();
    }

    final ordered = <ui.Image>[];
    final keys = byPresentation.keys.toList()..sort();
    for (final k in keys) {
      ordered.add(byPresentation[k]!);
    }
    return ordered;
  }

  static Future<ui.Image> _rgbaToImage(Uint8List rgba, int width, int height) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      rgba,
      width,
      height,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }
}
