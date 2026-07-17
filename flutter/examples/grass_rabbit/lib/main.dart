// AVAL Flutter port — grass-rabbit example.
//
// A thin consumer of the aval_flutter package's AvalView widget (the Flutter
// equivalent of the web player's <aval-video> element): the mansion-woman
// asset is decoded per-platform (Rust FFI natively, WebCodecs on web) and
// driven by the aval_graph MotionGraphEngine; this app only supplies chrome
// (maximize/zoom, state badge, hints) and side-band unit audio.

import 'package:aval_flutter/aval_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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

class _RabbitPageState extends State<RabbitPage> {
  final AvalPlayerController _controller = AvalPlayerController();
  final UnitAudioPlayer _audio = UnitAudioPlayer();

  /// One AvalView instance shared by the compact and maximized layouts: the
  /// GlobalKey reparents (rather than recreates) its state on toggle, so the
  /// presentation clock and audio don't restart.
  final GlobalKey _avalViewKey = GlobalKey();

  /// When true, video fills the window/screen (contain + pinch-zoom). The app
  /// starts maximized so the whole scene is the immediate presentation.
  bool _maximized = true;

  /// Pinch/pan transform while maximized.
  final TransformationController _zoomController = TransformationController();

  @override
  void initState() {
    super.initState();
    // App starts maximized (see [_maximized]); apply immersive chrome to match.
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _controller.addListener(_onControllerChanged);
    _controller.loadAsset('assets/mansion-woman.avl/h264.avl');
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
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

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _zoomController.dispose();
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    _audio.dispose();
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
          decoder: _controller.decoderDescription,
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
              constraints:
                  BoxConstraints(minHeight: constraints.maxHeight - 48),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('AVAL · mansion-woman',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    '${_controller.totalFrames} frames · '
                    '${_controller.unitFrames.length} units · '
                    '${_controller.canvasWidth}×${_controller.canvasHeight} · '
                    '${_controller.frameRateNumerator}fps · '
                    '${_controller.decoderDescription}',
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
                  _StateBadge(controller: _controller),
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
                _StateBadge(controller: _controller),
                const SizedBox(height: 8),
                Text(
                  defaultTargetPlatform == TargetPlatform.iOS ||
                          defaultTargetPlatform == TargetPlatform.android
                      ? 'Long-press → "hi" · Tap → "great"'
                      : 'Hover → "hi" · Tap → "great"',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.white70,
                        shadows: const [
                          Shadow(blurRadius: 6, color: Colors.black87),
                        ],
                      ),
                ),
                const SizedBox(height: 4),
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
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(borderRadius),
        border: showBorder ? Border.all(color: Colors.white12) : null,
        color: Colors.black,
      ),
      clipBehavior: Clip.antiAlias,
      child: AvalView(
        key: _avalViewKey,
        controller: _controller,
        fit: fit,
        onDoubleTap: onDoubleTap,
        // Side-band audio: the compiled .avl is video-only; AAC clips live
        // beside it as Flutter assets and follow unit switches.
        onUnitChanged: (unitId, looping) =>
            _audio.playUnit(unitId, loop: looping),
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

/// Shows the graph's visual state, plus the requested state while a transition
/// is pending — the label proves the MotionGraphEngine reacts to hover.
class _StateBadge extends StatelessWidget {
  const _StateBadge({required this.controller});

  final AvalPlayerController controller;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: controller.ticks,
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
                const Text('  →  ',
                    style: TextStyle(color: Colors.amberAccent)),
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
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const CircularProgressIndicator(),
        const SizedBox(height: 16),
        Text('Decoding idle-loop via $unitDecoderDescription…'),
      ],
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.error, required this.decoder});

  final Object error;
  final String decoder;

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
          SelectableText('decoder: $decoder',
              style: const TextStyle(color: Colors.white38, fontSize: 12)),
        ],
      ),
    );
  }
}
