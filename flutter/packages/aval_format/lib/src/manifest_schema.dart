/// Version-1.0 manifest schema composition root.
///
/// Dart port of `packages/format/src/manifest-schema.ts`.
library;

import 'constants.dart' show resolveFormatBudgets;
import 'errors.dart';
import 'manifest_graph_schema.dart';
import 'manifest_limits_schema.dart';
import 'manifest_relations.dart';
import 'manifest_rendition_schema.dart';
import 'manifest_unit_schema.dart';
import 'manifest_validation.dart';
import 'model.dart';
import 'video/codec_string.dart' show videoBitstreamByCodec, videoCodecs;

const List<String> _topLevelKeys = [
  'formatVersion',
  'generator',
  'codec',
  'bitstream',
  'layout',
  'canvas',
  'frameRate',
  'renditions',
  'units',
  'initialState',
  'states',
  'edges',
  'bindings',
  'readiness',
  'limits',
];

/// Validate, detach, and freeze the sole production manifest.
CompiledManifest validateCompiledManifest(Object? value, [FormatOptions? options]) {
  try {
    final budgets = resolveFormatBudgets(options);
    final input = record(value, 'manifest');
    exactKeys(input, _topLevelKeys, 'manifest');
    literal(input['formatVersion'], '1.0', 'formatVersion');
    final generator = generatorString(input['generator'], 'generator');
    final codec = oneOf(input['codec'], videoCodecs, 'codec');
    final bitstream = oneOf(input['bitstream'], ['annex-b', 'frame', 'low-overhead'], 'bitstream');
    if (bitstream != videoBitstreamByCodec[codec]) {
      invalid('bitstream', 'must be ${videoBitstreamByCodec[codec]} for $codec');
    }
    final layout = oneOf(input['layout'], ['opaque', 'packed-alpha'], 'layout');
    final canvas = cloneCanvas(input['canvas'], 'canvas');
    final frameRate = cloneFrameRate(input['frameRate'], 'frameRate');
    final renditions =
        cloneRenditions(input['renditions'], canvas, codec, layout, budgets, 'renditions');
    validateRawBlobCount(input['units'], renditions.length, budgets);
    final units = cloneUnits(input['units'], renditions, budgets, 'units');
    final initialState = identifier(input['initialState'], 'initialState');
    final states = cloneStates(input['states'], budgets, 'states');
    final edges = cloneEdges(input['edges'], budgets, 'edges');
    final bindings = cloneBindings(input['bindings'], budgets, 'bindings');
    final readiness = cloneReadiness(input['readiness'], budgets, 'readiness');
    final limits = cloneDeclaredLimits(input['limits'], renditions, budgets, 'limits');

    validateBlobCount(units, renditions, budgets);
    validateManifestRelations(ManifestRelationInput(
      initialState: initialState,
      renditions: renditions,
      units: units,
      states: states,
      edges: edges,
      bindings: bindings,
      readiness: readiness,
    ));

    return CompiledManifest(
      generator: generator,
      codec: codec,
      bitstream: bitstream,
      layout: layout,
      canvas: canvas,
      frameRate: frameRate,
      renditions: renditions,
      units: units,
      initialState: initialState,
      states: states,
      edges: edges,
      bindings: bindings,
      readiness: readiness,
      limits: limits,
    );
  } on FormatError {
    rethrow;
  } catch (_) {
    throw FormatError(FormatErrorCode.manifestInvalid, 'manifest validation failed');
  }
}
