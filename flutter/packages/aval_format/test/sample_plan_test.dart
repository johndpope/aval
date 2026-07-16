// Dart port of packages/format/test/sample-plan.test.ts.
import 'package:aval_format/src/errors.dart';
import 'package:aval_format/src/model.dart' show UnitV01, BodyUnitV01, SampleSpanV01;
import 'package:aval_format/src/sample_plan.dart';
import 'package:test/test.dart';

void main() {
  group('canonical sample plan', () {
    test('owns rendition-major, unit-major, frame-major ordinals and unit views', () {
      final plan = createCanonicalSamplePlan(
        [
          const PlanRendition(id: 'reference', profile: 'reference-rgba-v0'),
          const PlanRendition(id: 'video', profile: 'avc-annexb-opaque-v0'),
        ],
        [
          const PlanUnit(id: 'body', frameCount: 2),
          const PlanUnit(id: 'bridge', frameCount: 1),
        ],
        6,
        3,
      );

      final records = plan.records().map((slot) {
        return [slot.ordinal, slot.renditionId, slot.unitId, slot.frameIndex, slot.keyRequired];
      }).toList();
      expect(records, [
        [0, 'reference', 'body', 0, true],
        [1, 'reference', 'body', 1, true],
        [2, 'reference', 'bridge', 0, true],
        [3, 'video', 'body', 0, true],
        [4, 'video', 'body', 1, false],
        [5, 'video', 'bridge', 0, true],
      ]);
      expect(
        plan.spans.map((s) => [s.renditionId, s.unitId, s.sampleStart, s.sampleCount]).toList(),
        [
          ['reference', 'body', 0, 2],
          ['reference', 'bridge', 2, 1],
          ['video', 'body', 3, 2],
          ['video', 'bridge', 5, 1],
        ],
      );
      expect(plan.unitSpans[0].map((s) => s.sampleStart).toList(), [0, 3]);
      expect(plan.unitSpans[1].map((s) => s.sampleStart).toList(), [2, 5]);
      expect(plan.recordCount, 6);
      final slot4 = plan.recordAt(4);
      expect(slot4.ordinal, 4);
      expect(slot4.renditionIndex, 1);
      expect(slot4.renditionId, 'video');
      expect(slot4.unitIndex, 0);
      expect(slot4.unitId, 'body');
      expect(slot4.frameIndex, 1);
      expect(slot4.keyRequired, false);
    });

    test('validates wire spans against the same canonical plan', () {
      final plan = createCanonicalSamplePlan(
        [const PlanRendition(id: 'video', profile: 'avc-annexb-opaque-v0')],
        [const PlanUnit(id: 'body', frameCount: 2)],
        2,
        2,
      );
      final units = <UnitV01>[
        BodyUnitV01(
          id: 'body',
          frameCount: 2,
          playback: 'finite',
          ports: const [],
          samples: [
            SampleSpanV01(rendition: 'video', sampleStart: 0, sampleCount: 2, sha256: '0'.padRight(64, '0')),
          ],
        ),
      ];
      expect(() => validateCanonicalSampleSpans(plan, units), returnsNormally);

      final badUnits = <UnitV01>[
        BodyUnitV01(
          id: 'body',
          frameCount: 2,
          playback: 'finite',
          ports: const [],
          samples: [
            SampleSpanV01(rendition: 'video', sampleStart: 1, sampleCount: 2, sha256: '0'.padRight(64, '0')),
          ],
        ),
      ];
      expect(
        () => validateCanonicalSampleSpans(plan, badUnits, FormatErrorCode.indexInvalid),
        throwsA(predicate((e) => e is FormatError && e.code == FormatErrorCode.indexInvalid)),
      );
    });

    test('keeps plans above the former 3,600-record ceiling compact', () {
      final plan = createCanonicalSamplePlan(
        [const PlanRendition(id: 'video', profile: 'avc-annexb-opaque-v0')],
        [const PlanUnit(id: 'body', frameCount: 4001)],
        0xffffffff,
        0xffffffff,
      );

      expect(plan.recordCount, 4001);
      expect(plan.spans.length, 1);
      final slot = plan.recordAt(4000);
      expect(slot.ordinal, 4000);
      expect(slot.frameIndex, 4000);
      expect(slot.keyRequired, false);
    });

    test('rejects record counts outside the uint32 wire field', () {
      expect(
        () => createCanonicalSamplePlan(
          [const PlanRendition(id: 'video', profile: 'avc-annexb-opaque-v0')],
          [const PlanUnit(id: 'body', frameCount: 0x100000000)],
          9007199254740991,
          9007199254740991,
        ),
        throwsA(predicate((e) => e is FormatError && e.code == FormatErrorCode.integerUnsafe)),
      );
    });
  });
}
