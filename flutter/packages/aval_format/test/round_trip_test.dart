// Dart port of packages/format/test/round-trip.test.ts.
import 'package:aval_format/src/parser.dart';
import 'package:aval_format/src/writer.dart';
import 'package:test/test.dart';

import 'writer_fixture.dart';

void main() {
  group('canonical writer/parser round trip', () {
    test('reconstructs writer input from parsed metadata and caller payloads byte-identically', () {
      final callerInput = shuffledWriterInput(twoRenditionWriterInput());
      final first = writeCanonicalAsset(callerInput);
      final parsed = parseFrontIndex(first);
      final reconstructed = writerInputFromParsed(parsed, callerInput.chunks);
      final second = writeCanonicalAsset(reconstructed);

      expect(byteIdentity(first, second), true);
      final layout = validateCompleteAsset(bytes: second, frontIndex: parsed);
      expect(layout.fileRange.offset, 0);
      expect(layout.fileRange.length, second.length);
    });

    test('preserves every derived chunk span and payload byte range', () {
      final input = twoRenditionWriterInput();
      final bytes = writeCanonicalAsset(input);
      final parsed = parseFrontIndex(bytes);

      expect(parsed.records.length, input.chunks.length);
      for (var index = 0; index < parsed.records.length; index += 1) {
        final record = parsed.records[index];
        final slice = bytes.sublist(record.byteOffset, record.byteOffset + record.byteLength);
        expect(slice, input.chunks[index].bytes);
      }

      for (var unitIndex = 0; unitIndex < parsed.manifest.units.length; unitIndex += 1) {
        final unit = parsed.manifest.units[unitIndex];
        for (var renditionIndex = 0; renditionIndex < unit.chunks.length; renditionIndex += 1) {
          final span = unit.chunks[renditionIndex];
          final previousRenditions = parsed.manifest.units.fold<int>(
            0,
            (sum, candidate) =>
                sum +
                candidate.chunks
                    .sublist(0, renditionIndex)
                    .fold<int>(0, (inner, candidateSpan) => inner + candidateSpan.chunkCount),
          );
          final prefix = parsed.manifest.units
              .sublist(0, unitIndex)
              .fold<int>(0, (sum, candidate) => sum + candidate.chunks[renditionIndex].chunkCount);
          expect(span.chunkStart, previousRenditions + prefix);
          expect(span.frameCount, unit.frameCount);
        }
      }
    });
  });
}
