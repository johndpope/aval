/// Web [AvalUnitDecoder]: browser WebCodecs `VideoDecoder` via `dart:js_interop`.
///
/// The `.avl` chunks are H.264 Annex-B access units; per the WebCodecs spec a
/// `VideoDecoderConfig` with no `description` means Annex-B input, so the
/// chunks are submitted as-is — no WASM codec or transcoding involved. This is
/// the same decode engine the original TypeScript player
/// (`packages/player-web/src/decoder-worker`) uses.
///
/// Compiles under both dart2js and dart2wasm (`flutter build web --wasm`):
/// only `dart:js_interop`, no `dart:html`.
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'unit_decoder_types.dart';

AvalUnitDecoder createUnitDecoder() => WebCodecsUnitDecoder();

/// Backend description surfaced in the error view (`main.dart`).
String get unitDecoderDescription => 'WebCodecs VideoDecoder';

class WebCodecsUnitDecoder implements AvalUnitDecoder {
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
    final byPresentation = <int, ui.Image>{};
    final copies = <Future<void>>[];
    Object? decodeError;

    final decoder = VideoDecoder(
      VideoDecoderInit(
        output: (VideoFrame frame) {
          final timestamp = frame.timestamp;
          copies.add(
            _frameToImage(frame).then((img) {
              byPresentation[timestamp] = img;
            }).catchError((Object e) {
              decodeError ??= e;
            }),
          );
        }.toJS,
        error: (JSObject e) {
          decodeError ??= StateError('VideoDecoder error: $e');
        }.toJS,
      ),
    );

    try {
      decoder.configure(
        VideoDecoderConfig(
          codec: codecString,
          codedWidth: codedWidth,
          codedHeight: codedHeight,
          optimizeForLatency: true,
        ),
      );
      for (final chunk in chunks) {
        decoder.decode(
          EncodedVideoChunk(
            EncodedVideoChunkInit(
              type: chunk.randomAccess ? 'key' : 'delta',
              timestamp: chunk.presentationTimestamp,
              duration: chunk.duration,
              data: chunk.data.toJS,
            ),
          ),
        );
      }
      await decoder.flush().toDart;
    } finally {
      if (decoder.state != 'closed') decoder.close();
    }
    await Future.wait(copies);

    if (decodeError != null) {
      throw StateError('WebCodecs decode of unit "$unitId" failed: '
          '$decodeError (codec $codecString)');
    }

    final keys = byPresentation.keys.toList()..sort();
    return [for (final k in keys) byPresentation[k]!];
  }

  /// Copies one decoded [VideoFrame] out as an RGBA [ui.Image] and closes it.
  static Future<ui.Image> _frameToImage(VideoFrame frame) async {
    final width = frame.displayWidth;
    final height = frame.displayHeight;
    try {
      // copyTo with a format converts YUV→RGBA in the browser; with no
      // explicit layout the plane is tightly packed (stride == width * 4).
      //
      // The destination must stay a JS-heap array: under dart2wasm,
      // `Uint8List.toJS` COPIES (Dart typed data lives in the wasm heap), so
      // handing copyTo a throwaway copy leaves the Dart buffer all zeros —
      // a fully transparent image.
      final options = VideoFrameCopyToOptions(format: 'RGBA');
      final jsBuffer = Uint8List(frame.allocationSize(options)).toJS;
      await frame.copyTo(jsBuffer, options).toDart;
      return _rgbaToImage(jsBuffer.toDart, width, height);
    } finally {
      frame.close();
    }
  }

  /// `ui.decodeImageFromPixels` renders blank images under the wasm
  /// renderers; `ImageDescriptor.raw` is the supported path on web.
  static Future<ui.Image> _rgbaToImage(
      Uint8List rgba, int width, int height) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(rgba);
    final descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: width,
      height: height,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    try {
      final codec = await descriptor.instantiateCodec();
      try {
        final frame = await codec.getNextFrame();
        return frame.image;
      } finally {
        codec.dispose();
      }
    } finally {
      descriptor.dispose();
      buffer.dispose();
    }
  }
}

// ---------------------------------------------------------------------------
// Minimal WebCodecs interop — only the members used above.
// Mirrors https://www.w3.org/TR/webcodecs/.
// ---------------------------------------------------------------------------

@JS('VideoDecoder')
extension type VideoDecoder._(JSObject _) implements JSObject {
  external VideoDecoder(VideoDecoderInit init);
  external String get state;
  external void configure(VideoDecoderConfig config);
  external void decode(EncodedVideoChunk chunk);
  external JSPromise<JSAny?> flush();
  external void close();
}

extension type VideoDecoderInit._(JSObject _) implements JSObject {
  external VideoDecoderInit({JSFunction output, JSFunction error});
}

extension type VideoDecoderConfig._(JSObject _) implements JSObject {
  external VideoDecoderConfig({
    String codec,
    int codedWidth,
    int codedHeight,
    bool optimizeForLatency,
  });
}

@JS('EncodedVideoChunk')
extension type EncodedVideoChunk._(JSObject _) implements JSObject {
  external EncodedVideoChunk(EncodedVideoChunkInit init);
}

extension type EncodedVideoChunkInit._(JSObject _) implements JSObject {
  external EncodedVideoChunkInit({
    String type,
    int timestamp,
    int duration,
    JSUint8Array data,
  });
}

@JS('VideoFrame')
extension type VideoFrame._(JSObject _) implements JSObject {
  external int get timestamp;
  external int get displayWidth;
  external int get displayHeight;
  external int allocationSize(VideoFrameCopyToOptions options);
  external JSPromise<JSAny?> copyTo(
    JSUint8Array destination,
    VideoFrameCopyToOptions options,
  );
  external void close();
}

extension type VideoFrameCopyToOptions._(JSObject _) implements JSObject {
  external VideoFrameCopyToOptions({String format});
}
