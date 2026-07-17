/// Dart port of `packages/format/test/vp9-superframe.test.ts`.
library;

import 'dart:typed_data';

import 'package:aval_format/src/errors.dart';
import 'package:aval_format/src/vp9/index.dart';
import 'package:test/test.dart';

void main() {
  group('VP9 superframe parsing', () {
    test('splits hidden and displayed coded frames into owned bytes', () {
      const marker = 0xc1;
      final packet = Uint8List.fromList(
          [0x84, 0xaa, 0x86, 0xbb, 0xcc, marker, 2, 3, marker]);
      final frames = splitVp9Superframe(packet);
      expect(frames, equals([
        Uint8List.fromList([0x84, 0xaa]),
        Uint8List.fromList([0x86, 0xbb, 0xcc]),
      ]));
      packet.fillRange(0, packet.length, 0);
      expect(frames[0], equals(Uint8List.fromList([0x84, 0xaa])));
    });

    test('returns a detached single frame and rejects malformed indexes', () {
      final packet = Uint8List.fromList([0x86, 0x01]);
      final frames = splitVp9Superframe(packet);
      packet.fillRange(0, packet.length, 0);
      expect(frames, equals([Uint8List.fromList([0x86, 0x01])]));
      expect(
        () => splitVp9Superframe(Uint8List.fromList([0x84, 0xc1, 1, 1, 0xc1])),
        throwsA(predicate<Object>((error) =>
            error is FormatError && RegExp('sizes').hasMatch(error.message))),
      );
    });
  });
}
