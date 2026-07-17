// AVAL Flutter port — grass-rabbit desktop example.
//
// Proves the Phase 3 Dart<->Rust FFI round-trip: the idle-loop unit is decoded
// through the aval_decode Rust core (plain dart:ffi) and displayed as a looping
// animation, while the aval_graph MotionGraphEngine reacts to mouse hover and
// drives the state label (idle/entering/hover/exiting).

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'src/gpu_frame_painter.dart';
import 'src/rabbit_controller.dart';
import 'src/unit_audio.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
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
  final UnitAudioPlayer _audio = UnitAudioPlayer();
  late final Ticker _ticker;

  /// The frame currently on screen; the painter repaints when it changes.
  final ValueNotifier<ui.Image?> _displayImage = ValueNotifier<ui.Image?>(null);

  /// The compiled GPU frame-compositor shader (ARCHITECTURE.md §3.2). Null
  /// until loaded, during which `_buildVideoSurface` falls back to the CPU
  /// painter so first paint is never blocked on shader compilation.
  ui.FragmentProgram? _frameProgram;

  /// Rebuild signal for the state label (visual/requested state changed).
  final ValueNotifier<int> _stateEpoch = ValueNotifier<int>(0);

  Duration? _lastTick;
  double _accumulatedMicros = 0;
  int _stepCount = 0;
  bool _hovering = false;

  /// When true, video fills the window/screen (contain + pinch-zoom). The app
  /// starts maximized so the whole scene is the immediate presentation.
  bool _maximized = true;

  /// Pinch/pan transform while maximized.
  final TransformationController _zoomController = TransformationController();

  /// The unit currently being played and its unit-local frame counter.
  String _currentUnit = '';
  int _unitLocalFrame = 0;

  /// After a unit switch, hold the previous paint until the new unit is ready,
  /// then show its first frame once before advancing.
  bool _awaitingFirstFrame = false;

  @override
  void initState() {
    super.initState();
    // App starts maximized (see [_maximized]); apply immersive chrome to match.
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _ticker = createTicker(_onTick);
    loadFramePaintProgram().then((program) {
      if (!mounted) return;
      setState(() => _frameProgram = program);
    });
    _controller.load().then((_) {
      if (!mounted) return;
      setState(() {});
      if (_controller.loaded) {
        // Show the first unit's first frame immediately, then let the ticker
        // drive playback.
        _currentUnit = _controller.currentUnitId();
        _displayImage.value = _controller.imageFor(_currentUnit, 0);
        _syncAudio(_currentUnit);
        _ticker.start();
      }
    });
  }

  void _syncAudio(String unitId) {
    // Fire-and-forget; just_audio handles overlap by replacing the source.
    _audio.playUnit(unitId, loop: _controller.isLoopUnit(unitId));
  }

  void _setMaximized(bool value) {
    if (_maximized == value) return;
    setState(() {
      _maximized = value;
      // Reset zoom when entering/leaving maximized mode.
      _zoomController.value = Matrix4.identity();
    });
    // Immersive chrome on mobile; no-op / harmless on macOS desktop.
    if (value) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  void _resetZoom() {
    _zoomController.value = Matrix4.identity();
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
        _awaitingFirstFrame = true;
        _syncAudio(unit);
        // High-res units are decoded on demand; keep painting the previous
        // frame until the new unit has frames (no black flash).
        unawaited(_controller.ensureUnitDecoded(unit));
      } else if (_controller.isUnitReady(unit) && !_awaitingFirstFrame) {
        _unitLocalFrame++;
      }
      // Only advance the painted frame when the unit is ready; otherwise hold
      // whatever is currently on screen (last frame of previous unit).
      final next = _controller.imageFor(unit, _unitLocalFrame);
      if (next != null) {
        _displayImage.value = next;
        _awaitingFirstFrame = false;
      }
    }
    // Cheap: bump the label epoch every step; the label widget only rebuilds
    // when the rendered string actually changes.
    _stateEpoch.value = _stepCount;
  }

  void _setHover(bool hovering) {
    if (_hovering == hovering) return;
    _hovering = hovering;
    if (hovering) {
      // engagement.on → "hi" event (mansion-woman binding).
      _controller.onEngagementOn();
    }
    // engagement.off has no binding; hi→idle is completion-triggered.
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _zoomController.dispose();
    _ticker.dispose();
    _displayImage.dispose();
    _stateEpoch.dispose();
    _audio.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF101014),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_controller.error != null) {
      return Center(
        child: _ErrorView(
          error: _controller.error!,
          libPath: avalDecodeLibPath,
        ),
      );
    }
    if (!_controller.loaded) {
      return const Center(child: _LoadingView());
    }
    if (_maximized) {
      return _buildMaximized();
    }
    return SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight - 48),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('AVAL · mansion-woman',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    '${_controller.totalFrames} frames · ${_controller.unitFrames.length} units · '
                    '${_controller.canvasWidth}×${_controller.canvasHeight} · '
                    '${_controller.frameRateNumerator}fps · FFI decode',
                    textAlign: TextAlign.center,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: Colors.white54),
                  ),
                  const SizedBox(height: 16),
                  Align(
                    alignment: Alignment.center,
                    child: _buildVideo(maxWidth: 720),
                  ),
                  const SizedBox(height: 16),
                  _StateBadge(controller: _controller, epoch: _stateEpoch),
                  const SizedBox(height: 12),
                  Text(
                    defaultTargetPlatform == TargetPlatform.iOS ||
                            defaultTargetPlatform == TargetPlatform.android
                        ? 'Long-press → "hi" · Tap → "great"'
                        : 'Hover → "hi" · Tap → "great" · Drives the state graph',
                    textAlign: TextAlign.center,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: Colors.white38),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// Full-screen presentation: video **covers** the display (no letterbox),
  /// with pinch-to-zoom / pan. Double-tap resets zoom.
  Widget _buildMaximized() {
    final size = MediaQuery.sizeOf(context);
    // Use full physical screen (including under notch) so cover truly fills.
    final availH = size.height;
    final availW = size.width;
    final padding = MediaQuery.paddingOf(context);

    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: InteractiveViewer(
            transformationController: _zoomController,
            minScale: 1.0,
            maxScale: 5.0,
            // Clamp panning to the content edges so dragging can never reveal
            // the black background behind the video (no over-pan into the void).
            boundaryMargin: EdgeInsets.zero,
            clipBehavior: Clip.hardEdge,
            child: SizedBox(
              width: availW,
              height: availH,
              child: _buildVideoSurface(
                borderRadius: 0,
                showBorder: false,
                // contain (not cover) so the *whole* landscape frame is the
                // zoom/pan coordinate space. cover would crop the frame to a
                // center slice before zooming, making the rest of the scene
                // unreachable. Letterbox bars at scale 1.0 in portrait are the
                // honest framing of a 16:9 video and vanish as you zoom in.
                fit: BoxFit.contain,
                // Double-tap resets zoom without firing "great".
                onDoubleTap: _resetZoom,
              ),
            ),
          ),
        ),
        Positioned(
          top: padding.top + 8,
          right: padding.right + 8,
          child: _MaximizeButton(
            maximized: true,
            onPressed: () => _setMaximized(false),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: padding.bottom + 12,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _StateBadge(controller: _controller, epoch: _stateEpoch),
                const SizedBox(height: 8),
                Text(
                  'Pinch to zoom · Double-tap to reset',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.white54,
                        shadows: const [
                          Shadow(blurRadius: 6, color: Colors.black87),
                        ],
                      ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildVideo({required double maxWidth}) {
    final aspect = _controller.canvasWidth / _controller.canvasHeight;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth.clamp(0.0, maxWidth)
            : maxWidth;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            SizedBox(
              width: width,
              child: AspectRatio(
                aspectRatio: aspect,
                child: _buildVideoSurface(
                  borderRadius: 12,
                  showBorder: true,
                ),
              ),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: _MaximizeButton(
                maximized: false,
                onPressed: () => _setMaximized(true),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildVideoSurface({
    required double borderRadius,
    required bool showBorder,
    BoxFit fit = BoxFit.contain,
    VoidCallback? onDoubleTap,
  }) {
    return MouseRegion(
      onEnter: (_) => _setHover(true),
      onExit: (_) => _setHover(false),
      child: GestureDetector(
        onTap: () {
          if (_controller.loaded) _controller.onActivate();
        },
        // Mobile has no hover: long-press stands in for engagement.on → "hi".
        onLongPress: () {
          if (_controller.loaded) _controller.onEngagementOn();
        },
        onDoubleTap: onDoubleTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(borderRadius),
            border: showBorder ? Border.all(color: Colors.white12) : null,
            color: Colors.black,
          ),
          clipBehavior: Clip.antiAlias,
          child: RepaintBoundary(
            child: CustomPaint(
              painter: _frameProgram != null
                  ? GpuFramePainter(
                      image: _displayImage,
                      program: _frameProgram!,
                      fit: fit,
                    )
                  : _FramePainter(image: _displayImage, fit: fit),
              // Video repaints every frame, so the layer must never be
              // raster-cached. Without this, InteractiveViewer's parent
              // Transform (pan/zoom) triggers the raster cache to reuse a
              // frozen snapshot of the video while dragging.
              willChange: true,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
  }
}

/// Toggle between compact and full-height video presentation.
class _MaximizeButton extends StatelessWidget {
  const _MaximizeButton({required this.maximized, required this.onPressed});

  final bool maximized;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.55),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: IconButton(
        tooltip: maximized ? 'Exit fullscreen' : 'Fullscreen · zoom',
        icon: Icon(
          maximized ? Icons.fullscreen_exit : Icons.fullscreen,
          color: Colors.white,
        ),
        onPressed: onPressed,
      ),
    );
  }
}

/// Paints the current decoded frame. [fit] is [BoxFit.contain] in compact mode
/// and [BoxFit.cover] when maximized so the frame fills the screen.
class _FramePainter extends CustomPainter {
  _FramePainter({required this.image, this.fit = BoxFit.contain})
      : super(repaint: image);

  final ValueListenable<ui.Image?> image;
  final BoxFit fit;

  @override
  void paint(Canvas canvas, Size size) {
    final img = image.value;
    if (img == null) return;
    final src = Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble());
    final fitted = applyBoxFit(fit, src.size, size);
    final inputSubrect = Alignment.center.inscribe(
      fitted.source,
      src,
    );
    final dstRect = Alignment.center.inscribe(
      fitted.destination,
      Offset.zero & size,
    );
    canvas.drawImageRect(
      img,
      inputSubrect,
      dstRect,
      Paint()..filterQuality = FilterQuality.high,
    );
  }

  @override
  bool shouldRepaint(_FramePainter oldDelegate) =>
      oldDelegate.image != image || oldDelegate.fit != fit;
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
