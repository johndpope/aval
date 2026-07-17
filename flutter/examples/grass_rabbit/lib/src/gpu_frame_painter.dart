/// GPU-accelerated frame compositor for the decoded `aval_decode` picture.
///
/// Replaces the CPU `Canvas.drawImageRect` path with a `dart:ui`
/// `FragmentProgram` (Impeller/SkSL) shader, per the recommendation in
/// `flutter/ARCHITECTURE.md` §3.2: the fit/UV-remap math that the web
/// player runs in a WebGL2 fragment shader now runs in a real GPU shader
/// here too, instead of on the CPU.
library;

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

/// Loads and caches the compiled `shaders/frame.frag` program once per
/// isolate. `FragmentProgram.fromAsset` itself already memoizes by asset
/// key, but caching the [Future] here avoids redundant concurrent loads.
Future<ui.FragmentProgram> loadFramePaintProgram() =>
    _programFuture ??= ui.FragmentProgram.fromAsset('shaders/frame.frag');

Future<ui.FragmentProgram>? _programFuture;

/// Paints the current decoded frame with a GPU fragment shader instead of
/// [Canvas.drawImageRect]. Uniform layout mirrors the web player's
/// `FRAME_FRAGMENT_SHADER_SOURCE` (`u_color_uv`, `u_alpha_uv`,
/// `u_output_rect`, `u_has_alpha`) so a future packed-alpha `aval_decode`
/// profile only needs to start passing `alphaUv`/`hasAlpha`, not touch the
/// shader or this painter's structure.
class GpuFramePainter extends CustomPainter {
  GpuFramePainter({
    required this.image,
    required this.program,
    this.fit = BoxFit.contain,
  }) : super(repaint: image);

  final ValueListenable<ui.Image?> image;
  final ui.FragmentProgram program;
  final BoxFit fit;

  @override
  void paint(Canvas canvas, Size size) {
    final img = image.value;
    if (img == null) return;

    final srcSize = Size(img.width.toDouble(), img.height.toDouble());
    final fitted = applyBoxFit(fit, srcSize, size);
    final inputSubrect = Alignment.center.inscribe(
      fitted.source,
      Offset.zero & srcSize,
    );
    final dstRect = Alignment.center.inscribe(
      fitted.destination,
      Offset.zero & size,
    );
    if (dstRect.width <= 0 || dstRect.height <= 0) return;

    final shader = program.fragmentShader()
      // u_color_uv: normalized offset/scale of the fitted source crop within
      // the full decoded picture.
      ..setFloat(0, inputSubrect.left / srcSize.width)
      ..setFloat(1, inputSubrect.top / srcSize.height)
      ..setFloat(2, inputSubrect.width / srcSize.width)
      ..setFloat(3, inputSubrect.height / srcSize.height)
      // u_alpha_uv: unused while u_has_alpha is 0; zeroed for determinism.
      ..setFloat(4, 0)
      ..setFloat(5, 0)
      ..setFloat(6, 0)
      ..setFloat(7, 0)
      // u_output_rect: destination rect in this painter's local coordinate
      // space, matching FlutterFragCoord()'s coordinate system.
      ..setFloat(8, dstRect.left)
      ..setFloat(9, dstRect.top)
      ..setFloat(10, dstRect.width)
      ..setFloat(11, dstRect.height)
      // u_has_alpha: aval_decode has no packed-alpha profile yet.
      ..setFloat(12, 0)
      ..setImageSampler(0, img);

    canvas.drawRect(dstRect, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(GpuFramePainter oldDelegate) =>
      oldDelegate.image != image ||
      oldDelegate.fit != fit ||
      oldDelegate.program != program;
}
