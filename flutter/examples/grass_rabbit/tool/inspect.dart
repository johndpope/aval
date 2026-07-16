// Standalone inspector: parses the bundled .avl and prints the manifest facts
// this example relies on (coded dims, units, idle-loop access-unit records).
// Run: dart run tool/inspect.dart
import 'dart:io';
import 'package:aval_format/aval_format.dart';

void main() {
  final bytes = File('assets/grass-rabbit.avl').readAsBytesSync();
  final parsed = parseFrontIndex(bytes);
  final m = parsed.manifest;
  stdout.writeln('canvas ${m.canvas.width}x${m.canvas.height} fit=${m.canvas.fit}');
  stdout.writeln('frameRate ${m.frameRate.numerator}/${m.frameRate.denominator}');
  stdout.writeln('initialState ${m.initialState}');
  for (final r in m.renditions) {
    stdout.writeln('rendition ${r.id} profile=${r.profile} codec=${r.codec} '
        'coded=${r.codedWidth}x${r.codedHeight} type=${r.runtimeType}');
    if (r is AvcPackedAlphaRenditionV01) {
      stdout.writeln('  colorRect=${r.colorRect.x},${r.colorRect.y},${r.colorRect.width},${r.colorRect.height}'
          ' alphaRect=${r.alphaRect.x},${r.alphaRect.y},${r.alphaRect.width},${r.alphaRect.height}');
    }
  }
  for (var i = 0; i < m.units.length; i++) {
    final u = m.units[i];
    stdout.writeln('unit[$i] ${u.id} kind=${u.kind} frameCount=${u.frameCount}');
  }
  stdout.writeln('states: ${m.states.map((s) => s.id).join(", ")}');
  stdout.writeln('total records: ${parsed.records.length}');
  final idleIdx = m.units.indexWhere((u) => u.id == 'idle-loop');
  final idle = parsed.records.where((r) => r.unitIndex == idleIdx && r.renditionIndex == 0).toList()
    ..sort((a, b) => a.frameIndex.compareTo(b.frameIndex));
  stdout.writeln('idle-loop unitIndex=$idleIdx records=${idle.length} '
      'firstKey=${idle.first.key} firstOff=${idle.first.payloadOffset} firstLen=${idle.first.payloadLength}');
}
