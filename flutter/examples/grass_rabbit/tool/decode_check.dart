// Headless proof of the Phase 3 Dart<->Rust FFI decode round-trip.
// Reuses the example's real FFI bindings (lib/src/aval_ffi.dart) and the
// aval_format parser to decode the idle-loop unit from grass-rabbit.avl.
//
// Run: dart run tool/decode_check.dart
//   (uses AVAL_DECODE_LIB env var if set, else the default cargo artifact)
import 'dart:io';
import 'dart:typed_data';

import 'package:aval_format/aval_format.dart';
import 'package:grass_rabbit/src/aval_ffi.dart';

void main() {
  final libPath = Platform.environment['AVAL_DECODE_LIB'] ??
      '../../rust/aval_decode/target/release/libaval_decode.dylib';
  stdout.writeln('dylib: $libPath');

  final bytes = File('assets/grass-rabbit.avl').readAsBytesSync();
  final parsed = parseFrontIndex(bytes);
  final manifest = parsed.manifest;
  final rendition = manifest.renditions.first;

  final bindings = AvalDecodeBindings.open(libPath);
  final expectedLen = rendition.codedWidth * rendition.codedHeight * 4;
  var allOk = true;
  var grandTotal = 0;

  for (var u = 0; u < manifest.units.length; u++) {
    final unit = manifest.units[u];
    final recs = parsed.records
        .where((r) => r.unitIndex == u && r.renditionIndex == 0)
        .toList()
      ..sort((a, b) => a.frameIndex.compareTo(b.frameIndex));

    final session = AvalDecoderSession.create(bindings);
    var decoded = 0;
    var lenOk = true;
    try {
      session.configure(
          codedWidth: rendition.codedWidth, codedHeight: rendition.codedHeight);
      session.activateGeneration(1);
      for (var i = 0; i < recs.length; i++) {
        final r = recs[i];
        final au = Uint8List.sublistView(
            bytes, r.payloadOffset, r.payloadOffset + r.payloadLength);
        final fid = session.submit(
          ordinal: i,
          timestamp: i,
          duration: 1,
          unitFrame: i,
          unitFrameCount: unit.frameCount,
          isKey: r.key,
          data: au,
          unitId: unit.id,
        );
        if (fid == null) continue;
        session.takeFrame<void>((v) {
          if (v.rgba.length != expectedLen) lenOk = false;
          decoded++;
        });
      }
    } finally {
      session.disposeSession();
    }
    grandTotal += decoded;
    final ok = decoded == recs.length && lenOk;
    allOk = allOk && ok;
    stdout.writeln('unit "${unit.id}": decoded $decoded/${recs.length} '
        '(${ok ? "OK" : "FAIL"})');
  }

  stdout.writeln('total frames decoded via FFI: $grandTotal');
  if (allOk) {
    stdout.writeln('OK: FFI decode round-trip verified for all units');
  } else {
    stderr.writeln('FAIL: decode mismatch');
    exit(1);
  }
}
