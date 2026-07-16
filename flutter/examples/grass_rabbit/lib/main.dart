// AVAL Flutter port — grass-rabbit desktop example.
//
// Proves the Phase 3 Dart<->Rust FFI round-trip: the idle-loop unit is decoded
// through the aval_decode Rust core (plain dart:ffi) and displayed as a looping
// animation, while the aval_graph MotionGraphEngine reacts to mouse hover and
// drives the state label (idle/entering/hover/exiting).

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'src/rabbit_controller.dart';

void main() {
  runApp(const GrassRabbitApp());
}

class GrassRabbitApp extends StatelessWidget {
  const GrassRabbitApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AVAL — grass-rabbit',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: const RabbitPage(),
    );
  }
}

class RabbitPage extends StatefulWidget {
  const RabbitPage({super.key});

  @override
  State<RabbitPage> createState() => _RabbitPageState();
}

class _RabbitPageState extends State<RabbitPage>
    with SingleTickerProviderStateMixin {
  final RabbitController _controller = RabbitController();
  late final Ticker _ticker;

  /// The frame currently on screen; the painter repaints when it changes.
  final ValueNotifier<ui.Image?> _displayImage = ValueNotifier<ui.Image?>(null);

  /// Rebuild signal for the state label (visual/requested state changed).
  final ValueNotifier<int> _stateEpoch = ValueNotifier<int>(0);

  Duration? _lastTick;
  double _accumulatedMicros = 0;
  int _stepCount = 0;
  bool _hovering = false;

  /// The unit currently being played and its unit-local frame counter.
  String _currentUnit = '';
  int _unitLocalFrame = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _controller.load().then((_) {
      if (!mounted) return;
      setState(() {});
      if (_controller.loaded) {
        // Show the first unit's first frame immediately, then let the ticker
        // drive playback.
        _currentUnit = _controller.currentUnitId();
        _displayImage.value = _controller.imageFor(_currentUnit, 0);
        _ticker.start();
      }
    });
  }

  void _onTick(Duration elapsed) {
    if (!_controller.loaded || _controller.totalFrames == 0) return;
    final last = _lastTick;
    _lastTick = elapsed;
    if (last == null) return;

    // Gate the display/graph clock to the manifest frame rate rather than the
    // display refresh rate.
    final frameMicros =
        1e6 * _controller.frameRateDenominator / _controller.frameRateNumerator;
    _accumulatedMicros += (elapsed - last).inMicroseconds;
    while (_accumulatedMicros >= frameMicros) {
      _accumulatedMicros -= frameMicros;
      _stepCount++;
      // Graph: advance one authored frame so completion/portal boundaries fire.
      _controller.tickGraph();
      // Video: follow the graph. When the graph's unit changes, restart the
      // unit-local frame counter (approximation of Phase 7-8 scheduling).
      final unit = _controller.currentUnitId();
      if (unit != _currentUnit) {
        _currentUnit = unit;
        _unitLocalFrame = 0;
      } else {
        _unitLocalFrame++;
      }
      _displayImage.value = _controller.imageFor(unit, _unitLocalFrame);
    }
    // Cheap: bump the label epoch every step; the label widget only rebuilds
    // when the rendered string actually changes.
    _stateEpoch.value = _stepCount;
  }

  void _setHover(bool hovering) {
    if (_hovering == hovering) return;
    _hovering = hovering;
    if (hovering) {
      _controller.onHoverEnter();
    } else {
      _controller.onHoverLeave();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _displayImage.dispose();
    _stateEpoch.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF101014),
      body: Center(child: _buildBody()),
    );
  }

  Widget _buildBody() {
    if (_controller.error != null) {
      return _ErrorView(
        error: _controller.error!,
        libPath: avalDecodeLibPath,
      );
    }
    if (!_controller.loaded) {
      return const _LoadingView();
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 24),
        Text('AVAL · grass-rabbit',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          '${_controller.totalFrames} frames · ${_controller.unitFrames.length} units · '
          '${_controller.canvasWidth}×${_controller.canvasHeight} · '
          '${_controller.frameRateNumerator}fps · FFI decode',
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: Colors.white54),
        ),
        const SizedBox(height: 16),
        _buildVideo(),
        const SizedBox(height: 16),
        _StateBadge(controller: _controller, epoch: _stateEpoch),
        const SizedBox(height: 12),
        Text('Hover the video to drive the state graph',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: Colors.white38)),
      ],
    );
  }

  Widget _buildVideo() {
    final aspect = _controller.canvasWidth / _controller.canvasHeight;
    return MouseRegion(
      onEnter: (_) => _setHover(true),
      onExit: (_) => _setHover(false),
      child: Container(
        width: 720,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white12),
        ),
        clipBehavior: Clip.antiAlias,
        child: AspectRatio(
          aspectRatio: aspect,
          child: RepaintBoundary(
            child: CustomPaint(
              painter: _FramePainter(image: _displayImage),
            ),
          ),
        ),
      ),
    );
  }
}

/// Paints the current decoded frame with BoxFit.contain (matches the manifest
/// canvas fit). Repaints whenever [image] changes.
class _FramePainter extends CustomPainter {
  _FramePainter({required this.image}) : super(repaint: image);

  final ValueListenable<ui.Image?> image;

  @override
  void paint(Canvas canvas, Size size) {
    final img = image.value;
    if (img == null) return;
    final src = Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble());
    final fitted = applyBoxFit(BoxFit.contain, src.size, size);
    final dstRect = Alignment.center.inscribe(
      fitted.destination,
      Offset.zero & size,
    );
    canvas.drawImageRect(
        img, src, dstRect, Paint()..filterQuality = FilterQuality.medium);
  }

  @override
  bool shouldRepaint(_FramePainter oldDelegate) =>
      oldDelegate.image != image;
}

/// Shows the graph's visual state, plus the requested state while a transition
/// is pending — the label proves the MotionGraphEngine reacts to hover.
class _StateBadge extends StatelessWidget {
  const _StateBadge({required this.controller, required this.epoch});

  final RabbitController controller;
  final ValueListenable<int> epoch;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: epoch,
      builder: (context, value, child) {
        final visual = controller.visualState;
        final requested = controller.requestedState;
        final pending = requested != visual;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          decoration: BoxDecoration(
            color: pending ? const Color(0xFF3A2E12) : const Color(0xFF16261A),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
                color: pending ? Colors.amberAccent : Colors.greenAccent,
                width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('state: ',
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.6))),
              Text(visual,
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 16)),
              if (pending) ...[
                const Text('  →  ', style: TextStyle(color: Colors.amberAccent)),
                Text(requested,
                    style: const TextStyle(
                        color: Colors.amberAccent, fontSize: 16)),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _LoadingView extends StatelessWidget {
  const _LoadingView();

  @override
  Widget build(BuildContext context) {
    return const Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        CircularProgressIndicator(),
        SizedBox(height: 16),
        Text('Decoding idle-loop via aval_decode (FFI)…'),
      ],
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.error, required this.libPath});

  final Object error;
  final String libPath;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, color: Colors.redAccent, size: 40),
          const SizedBox(height: 16),
          const Text('Failed to load grass-rabbit',
              style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text('$error',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70)),
          const SizedBox(height: 16),
          SelectableText('AVAL_DECODE_LIB = $libPath',
              style: const TextStyle(color: Colors.white38, fontSize: 12)),
        ],
      ),
    );
  }
}
