// Smoke tests for the grass-rabbit example.
//
// The `graph reacts to hover` test is the important, deterministic one: it
// exercises the same parse + MotionGraphEngine wiring the UI uses (no FFI, no
// widgets) and proves the graph transitions idle -> entering -> hover on a
// hover.enter event, at the authored portal boundary.

import 'dart:io';

import 'package:aval_format/aval_format.dart';
import 'package:aval_graph/aval_graph.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grass_rabbit/main.dart';
import 'package:grass_rabbit/src/rabbit_controller.dart';

void main() {
  test('parse grass-rabbit.avl: header + manifest + access-unit index', () {
    final bytes = File('assets/grass-rabbit.avl').readAsBytesSync();
    final parsed = parseFrontIndex(bytes);
    expect(parsed.manifest.canvas.width, 1280);
    expect(parsed.manifest.canvas.height, 720);
    expect(parsed.manifest.frameRate.numerator, 24);
    expect(parsed.records, isNotEmpty);
    expect(parsed.manifest.units.map((u) => u.id), contains('idle-loop'));
  });

  test('graph reacts to hover: idle -> entering -> hover', () {
    final bytes = File('assets/grass-rabbit.avl').readAsBytesSync();
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

    // Drain the intro one-shot (30 frames) so we settle into idle.
    for (var i = 0; i < 60; i++) {
      tick();
    }
    expect(visual(), 'idle');

    // Hover in: requested state flips immediately; visual commits at the portal.
    engine.send('hover.enter');
    expect(engine.snapshot().requestedState, 'entering');

    var reachedEntering = false;
    var reachedHover = false;
    for (var i = 0; i < 1000 && !reachedHover; i++) {
      tick();
      if (visual() == 'entering') reachedEntering = true;
      if (visual() == 'hover') reachedHover = true;
    }
    expect(reachedEntering, isTrue, reason: 'never entered "entering"');
    expect(reachedHover, isTrue, reason: 'never reached "hover"');
  });

  test('displayed unit follows the graph: idle-loop -> hover-in -> hover-loop',
      () {
    // The unit-for-state mapping used to drive the video.
    expect(RabbitController.unitForState['idle'], 'idle-loop');
    expect(RabbitController.unitForState['entering'], 'hover-in');
    expect(RabbitController.unitForState['hover'], 'hover-loop');
    expect(RabbitController.unitForState['exiting'], 'hover-out');
    expect(RabbitController.loopUnitIds, containsAll(['idle-loop', 'hover-loop']));

    final bytes = File('assets/grass-rabbit.avl').readAsBytesSync();
    final parsed = parseFrontIndex(bytes);

    final controller = RabbitController();
    controller.engine
      ..install(parsed.graph)
      ..beginAnimated();

    var ordinal = BigInt.zero;
    void tick() {
      controller.engine
          .tick(MotionGraphTickOptions(contentOrdinal: ordinal));
      ordinal += BigInt.one;
    }

    // Intro plays first, then settles into idle-loop.
    expect(controller.currentUnitId(), 'intro');
    for (var i = 0; i < 60; i++) {
      tick();
    }
    expect(controller.currentUnitId(), 'idle-loop');

    controller.engine.send('hover.enter');
    var sawHoverIn = false;
    var sawHoverLoop = false;
    for (var i = 0; i < 1000 && !sawHoverLoop; i++) {
      tick();
      final unit = controller.currentUnitId();
      if (unit == 'hover-in') sawHoverIn = true;
      if (unit == 'hover-loop') sawHoverLoop = true;
    }
    expect(sawHoverIn, isTrue, reason: 'video never switched to hover-in');
    expect(sawHoverLoop, isTrue, reason: 'video never switched to hover-loop');

    controller.dispose();
  });

  testWidgets('app builds without throwing', (tester) async {
    await tester.pumpWidget(const GrassRabbitApp());
    // First frame shows the loading view while decode runs.
    expect(find.byType(GrassRabbitApp), findsOneWidget);
  });
}
