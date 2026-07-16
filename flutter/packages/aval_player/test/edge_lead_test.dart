// Port of packages/player-web/src/runtime/edge-lead.test.ts.
import 'package:aval_player/aval_player.dart';
import 'package:test/test.dart';

void main() {
  group('edge-specific consecutive lead', () {
    for (final testCase in const [
      [0, 2],
      [1, 2],
      [2, 3],
      [4, 5],
      [5, 6],
      [6, 6],
      [12, 6],
    ]) {
      final transitionFrames = testCase[0];
      final required = testCase[1];
      test(
        'requires $transitionFrames bridge frames plus target entry within a '
        'six-frame ring',
        () {
          expect(
            calculateRequiredEdgeLeadFrames(RequiredEdgeLeadInput(
              transitionFrames: transitionFrames,
              ringCapacity: 6,
            )),
            required,
          );
        },
      );
    }

    test('requires two frames for a transitionless edge', () {
      expect(
        planEdgeLead(const EdgeLeadInput(
          transitionFrames: 0,
          ringCapacity: 6,
          availableConsecutiveFrames: 1,
        )),
        const EdgeLeadPlan(
          transitionFrames: 0,
          targetEntryOffset: 0,
          firstPresentation: EdgeLeadFirstPresentation.targetBody,
          requiredConsecutiveFrames: 2,
          availableConsecutiveFrames: 1,
          missingConsecutiveFrames: 1,
          ready: false,
        ),
      );
    });

    test('counts a one-frame bridge and target frame zero before departure', () {
      final plan = planEdgeLead(const EdgeLeadInput(
        transitionFrames: 1,
        ringCapacity: 6,
        availableConsecutiveFrames: 2,
      ));

      expect(
        plan,
        const EdgeLeadPlan(
          transitionFrames: 1,
          targetEntryOffset: 1,
          firstPresentation: EdgeLeadFirstPresentation.bridge,
          requiredConsecutiveFrames: 2,
          availableConsecutiveFrames: 2,
          missingConsecutiveFrames: 0,
          ready: true,
        ),
      );
    });

    test('uses the complete short bridge plus target and caps longer bridges',
        () {
      expect(
        calculateRequiredEdgeLeadFrames(const RequiredEdgeLeadInput(
          transitionFrames: 10,
          ringCapacity: 12,
        )),
        11,
      );
      expect(
        calculateRequiredEdgeLeadFrames(const RequiredEdgeLeadInput(
          transitionFrames: 11,
          ringCapacity: 12,
        )),
        12,
      );
      expect(
        calculateRequiredEdgeLeadFrames(const RequiredEdgeLeadInput(
          transitionFrames: 12,
          ringCapacity: 12,
        )),
        12,
      );
      expect(
        calculateRequiredEdgeLeadFrames(const RequiredEdgeLeadInput(
          transitionFrames: 120,
          ringCapacity: 12,
        )),
        12,
      );
    });

    test('accepts exactly the required measured lead and rejects one less', () {
      final low = planEdgeLead(const EdgeLeadInput(
        transitionFrames: 4,
        ringCapacity: 6,
        availableConsecutiveFrames: 4,
      ));
      expect(low.ready, false);
      expect(low.missingConsecutiveFrames, 1);

      final ready = planEdgeLead(const EdgeLeadInput(
        transitionFrames: 4,
        ringCapacity: 6,
        availableConsecutiveFrames: 5,
      ));
      expect(ready.ready, true);
      expect(ready.missingConsecutiveFrames, 0);
    });

    for (final ringCapacity in [0, 5, 13, maxSafeInteger]) {
      test('rejects ring capacity $ringCapacity outside 6-12', () {
        expect(
          () => calculateRequiredEdgeLeadFrames(RequiredEdgeLeadInput(
            transitionFrames: 0,
            ringCapacity: ringCapacity,
          )),
          throwsRangeError,
        );
      });
    }

    test('rejects unsafe transition arithmetic and impossible measured lead',
        () {
      expect(
        () => calculateRequiredEdgeLeadFrames(const RequiredEdgeLeadInput(
          transitionFrames: maxSafeInteger,
          ringCapacity: 12,
        )),
        throwsA(
          isA<RangeError>().having(
            (e) => e.toString(),
            'message',
            contains('safe successor'),
          ),
        ),
      );
      expect(
        () => planEdgeLead(const EdgeLeadInput(
          transitionFrames: 0,
          ringCapacity: 6,
          availableConsecutiveFrames: 7,
        )),
        throwsA(
          isA<RangeError>().having(
            (e) => e.toString(),
            'message',
            contains('available consecutive'),
          ),
        ),
      );
      expect(
        () => planEdgeLead(const EdgeLeadInput(
          transitionFrames: -1,
          ringCapacity: 6,
          availableConsecutiveFrames: 0,
        )),
        throwsRangeError,
      );
    });
  });
}
