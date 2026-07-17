// Smoke tests for the grass-rabbit example.
//
// The graph tests are the important, deterministic ones: they exercise the
// same parse + MotionGraphEngine wiring AvalView uses (no FFI, no widgets)
// against the format-1.0 mansion-woman asset the app ships, and prove the
// graph transitions idle -> hi -> idle from a bound input event.

import 'dart:io';

import 'package:aval_flutter/aval_flutter.dart';
import 'package:aval_format/aval_format.dart';
import 'package:aval_graph/aval_graph.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grass_rabbit/main.dart';

const _assetPath = 'assets/mansion-woman.avl/h264.avl';

void main() {
  test('parse mansion-woman.avl: header + manifest + access-unit index', () {
    final bytes = File(_assetPath).readAsBytesSync();
    final parsed = parseFrontIndex(bytes);
    expect(parsed.manifest.canvas.width, 1280);
    expect(parsed.manifest.canvas.height, 720);
    expect(parsed.manifest.frameRate.numerator, 24);
    expect(parsed.records, isNotEmpty);
    expect(parsed.manifest.units.map((u) => u.id),
        containsAll(['idle-loop', 'hi', 'great']));
    // Input bindings drive the AvalView gesture mapping.
    expect(
      {for (final b in parsed.manifest.bindings) b.source: b.event},
      {'activate': 'great', 'engagement.on': 'hi'},
    );
  });

  test('graph reacts to engagement: idle -> hi -> idle', () {
    final bytes = File(_assetPath).readAsBytesSync();
    final parsed = parseFrontIndex(bytes);

    final engine = MotionGraphEngine()
      ..install(parsed.graph)
      ..beginAnimated();

    String visual() {
      final s = engine.snapshot();
      return s.visualState ?? parsed.manifest.initialState;
    }

    var ordinal = BigInt.zero;
    void tick() {
      engine.tick(MotionGraphTickOptions(contentOrdinal: ordinal));
      ordinal += BigInt.one;
    }

    for (var i = 0; i < 60; i++) {
      tick();
    }
    expect(visual(), 'idle');

    // engagement.on -> "hi": requested state flips immediately; visual
    // commits at the portal.
    engine.send('hi');
    expect(engine.snapshot().requestedState, 'hi');

    var reachedHi = false;
    for (var i = 0; i < 1000 && !reachedHi; i++) {
      tick();
      if (visual() == 'hi') reachedHi = true;
    }
    expect(reachedHi, isTrue, reason: 'never reached "hi"');

    // "hi" is a finite 240-frame unit whose completion edge returns to idle.
    var backToIdle = false;
    for (var i = 0; i < 1000 && !backToIdle; i++) {
      tick();
      if (visual() == 'idle') backToIdle = true;
    }
    expect(backToIdle, isTrue, reason: 'never completed back to "idle"');
  });

  test('displayed unit follows the graph: idle-loop -> hi -> idle-loop', () {
    final bytes = File(_assetPath).readAsBytesSync();
    final parsed = parseFrontIndex(bytes);

    // Graph + bindings only — no video bytes, no decoder.
    final controller = AvalPlayerController()
      ..installGraph(parsed.graph, bindings: parsed.manifest.bindings);

    // State→unit mapping and loop kinds are derived from the manifest graph.
    expect(controller.isLoopUnit('idle-loop'), isTrue);
    expect(controller.isLoopUnit('hi'), isFalse);
    expect(controller.isLoopUnit('great'), isFalse);

    for (var i = 0; i < 60; i++) {
      controller.tickGraph();
    }
    expect(controller.currentUnitId(), 'idle-loop');

    // The engagement.on binding resolves to the "hi" event.
    controller.sendSource('engagement.on');
    var sawHi = false;
    for (var i = 0; i < 1000 && !sawHi; i++) {
      controller.tickGraph();
      if (controller.currentUnitId() == 'hi') sawHi = true;
    }
    expect(sawHi, isTrue, reason: 'video never switched to hi');

    var backToIdle = false;
    for (var i = 0; i < 1000 && !backToIdle; i++) {
      controller.tickGraph();
      if (controller.currentUnitId() == 'idle-loop') backToIdle = true;
    }
    expect(backToIdle, isTrue, reason: 'video never returned to idle-loop');

    controller.dispose();
  });

  testWidgets('app builds without throwing', (tester) async {
    await tester.pumpWidget(const GrassRabbitApp());
    // First frame shows the loading view while decode runs.
    expect(find.byType(GrassRabbitApp), findsOneWidget);
  });
}
