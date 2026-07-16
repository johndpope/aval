// Port of packages/player-web/src/runtime/decode-timeline.test.ts.
//
// Adaptations from the TS test (documented, behavior-preserving):
//  * `Object.isFrozen` assertions become `List.unmodifiable`/immutable-value
//    checks — the "deeply immutable" test mutated the input rate object to
//    prove the timeline copied it; `RationalFrameRate` is immutable in Dart, so
//    the copy is proven by comparing the snapshot's frame rate instead.
//  * The `["unit", 1.5]` invalid-metadata case is omitted: the Dart API takes
//    an `int`, so a non-integer frame count is not representable.
import 'package:aval_player/aval_player.dart';
import 'package:test/test.dart';

List<Object> _identity(DecodeSampleMetadata sample) => [
      sample.generation,
      sample.ordinal,
      sample.unitId,
      sample.unitInstance,
      sample.unitFrame,
    ];

int _occurrenceEnd(List<DecodeSampleMetadata> samples) {
  final finalSample = samples.last;
  return finalSample.timestamp + finalSample.duration;
}

void main() {
  group('DecodeTimeline', () {
    test('assigns exact 30,000/1,001 timestamps without accumulating duration',
        () {
      final timeline = DecodeTimeline(
        const RationalFrameRate(numerator: 30000, denominator: 1001),
      );

      expect(timeline.activateNextGeneration(), 1);
      final samples = timeline.allocateUnitOccurrence('body', 7);

      expect(
        samples.map((sample) => sample.timestamp).toList(),
        [0, 33367, 66733, 100100, 133467, 166833, 200200],
      );
      expect(
        samples.map((sample) => sample.duration).toList(),
        [33367, 33366, 33367, 33367, 33366, 33367, 33367],
      );
      expect(
        _occurrenceEnd(samples),
        timestampForFrame(
          7,
          const RationalFrameRate(numerator: 30000, denominator: 1001),
        ),
      );
    });

    for (final testCase in const [
      {
        'rate': RationalFrameRate(numerator: 24, denominator: 1),
        'timestamps': [0, 41667, 83333, 125000],
      },
      {
        'rate': RationalFrameRate(numerator: 30, denominator: 1),
        'timestamps': [0, 33333, 66667, 100000],
      },
      {
        'rate': RationalFrameRate(numerator: 60, denominator: 1),
        'timestamps': [0, 16667, 33333, 50000],
      },
    ]) {
      final rate = testCase['rate'] as RationalFrameRate;
      final timestamps = testCase['timestamps'] as List<int>;
      test('uses the exact ${rate.numerator}/${rate.denominator} clock', () {
        final timeline = DecodeTimeline(rate);
        timeline.activateNextGeneration();

        expect(
          timeline
              .allocateUnitOccurrence('unit', timestamps.length)
              .map((sample) => sample.timestamp)
              .toList(),
          timestamps,
        );
      });
    }

    test('has no long-run drift or duplicate timestamp', () {
      const frameCount = 100000;
      const rate = RationalFrameRate(numerator: 60000, denominator: 1001);
      final timeline = DecodeTimeline(rate);
      timeline.activateNextGeneration();

      final samples = timeline.allocateUnitOccurrence('long-body', frameCount);
      var accumulatedDuration = 0;
      var previousTimestamp = -1;
      final timestamps = <int>{};
      for (final sample in samples) {
        expect(sample.timestamp, greaterThan(previousTimestamp));
        accumulatedDuration += sample.duration;
        previousTimestamp = sample.timestamp;
        timestamps.add(sample.timestamp);
      }

      expect(timestamps.length, frameCount);
      expect(accumulatedDuration, timestampForFrame(frameCount, rate));
      expect(_occurrenceEnd(samples), timestampForFrame(frameCount, rate));
    });

    test('keeps ordinals global and resets only unit instances per generation',
        () {
      final timeline =
          DecodeTimeline(const RationalFrameRate(numerator: 30, denominator: 1));

      expect(timeline.activateNextGeneration(), 1);
      final all = timeline.allocateUnitOccurrences(const [
        DecodeUnitOccurrence(unitId: 'intro', unitFrameCount: 2),
        DecodeUnitOccurrence(unitId: 'body', unitFrameCount: 3),
      ]);
      final first = all.sublist(0, 2);
      final second = all.sublist(2);
      expect(first.map(_identity).toList(), [
        [1, 0, 'intro', 0, 0],
        [1, 1, 'intro', 0, 1],
      ]);
      expect(second.map(_identity).toList(), [
        [1, 2, 'body', 1, 0],
        [1, 3, 'body', 1, 1],
        [1, 4, 'body', 1, 2],
      ]);

      expect(timeline.activateNextGeneration(), 2);
      final replacement = timeline.allocateUnitOccurrence('body', 2);
      expect(replacement.map(_identity).toList(), [
        [2, 5, 'body', 0, 0],
        [2, 6, 'body', 0, 1],
      ]);
      expect(
        replacement[0].timestamp,
        greaterThan(second.last.timestamp),
      );
      expect(
        timeline.snapshot(),
        const DecodeTimelineSnapshot(
          frameRate: RationalFrameRate(numerator: 30, denominator: 1),
          activeGeneration: 2,
          nextOrdinal: 7,
          nextUnitInstance: 1,
        ),
      );
    });

    test('returns deeply immutable sample metadata and snapshots', () {
      const rate = RationalFrameRate(numerator: 24, denominator: 1);
      final timeline = DecodeTimeline(rate);
      timeline.activateNextGeneration();

      final samples = timeline.allocateUnitOccurrence('unit', 2);
      final snapshot = timeline.snapshot();

      expect(
        () => samples.add(samples.first),
        throwsA(isA<UnsupportedError>()),
      );
      expect(
        snapshot.frameRate,
        const RationalFrameRate(numerator: 24, denominator: 1),
      );
    });

    test('rejects unsafe timestamp successors atomically', () {
      final timeline = DecodeTimeline(
        const RationalFrameRate(numerator: 1, denominator: 9007199254),
      );
      timeline.activateNextGeneration();

      expect(
        () => timeline.allocateUnitOccurrence('too-long', 2),
        throwsA(
          isA<RangeError>().having(
            (e) => e.toString(),
            'message',
            contains('safe-integer range'),
          ),
        ),
      );
      expect(timeline.snapshot().activeGeneration, 1);
      expect(timeline.snapshot().nextOrdinal, 0);
      expect(timeline.snapshot().nextUnitInstance, 0);

      final first = timeline.allocateUnitOccurrence('last-safe', 1);
      expect(first, hasLength(1));
      expect(
        () => timeline.allocateUnitOccurrence('overflow', 1),
        throwsA(
          isA<RangeError>().having(
            (e) => e.toString(),
            'message',
            contains('safe-integer range'),
          ),
        ),
      );
      expect(timeline.snapshot().activeGeneration, 1);
      expect(timeline.snapshot().nextOrdinal, 1);
      expect(timeline.snapshot().nextUnitInstance, 1);
    });

    test(
        'requires a generation and rejects invalid occurrence metadata '
        'atomically', () {
      final timeline =
          DecodeTimeline(const RationalFrameRate(numerator: 30, denominator: 1));

      expect(
        () => timeline.allocateUnitOccurrence('unit', 1),
        throwsA(
          isA<RangeError>().having(
            (e) => e.toString(),
            'message',
            contains('active generation'),
          ),
        ),
      );
      expect(timeline.snapshot().activeGeneration, isNull);
      expect(timeline.snapshot().nextOrdinal, 0);
      expect(timeline.snapshot().nextUnitInstance, 0);

      timeline.activateNextGeneration();
      expect(
        () => timeline.allocateUnitOccurrences(const []),
        throwsRangeError,
      );
      expect(
        () => timeline.allocateUnitOccurrences(const [
          DecodeUnitOccurrence(unitId: 'valid-first', unitFrameCount: 2),
          DecodeUnitOccurrence(unitId: 'invalid-second', unitFrameCount: 0),
        ]),
        throwsRangeError,
      );
      final invalidCases = <List<Object>>[
        ['', 1],
        ['x' * 129, 1],
        ['unit', 0],
        ['unit', -1],
        ['unit', maxSafeInteger + 1],
      ];
      for (final invalid in invalidCases) {
        expect(
          () => timeline.allocateUnitOccurrence(
            invalid[0] as String,
            invalid[1] as int,
          ),
          throwsRangeError,
        );
      }
      expect(timeline.snapshot().activeGeneration, 1);
      expect(timeline.snapshot().nextOrdinal, 0);
      expect(timeline.snapshot().nextUnitInstance, 0);
    });
  });
}
