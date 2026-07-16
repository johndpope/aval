/// Version-0.1 manifest schema composition root.
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

const List<String> _topLevelKeys = [
  'formatVersion',
  'generator',
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

/// Validates, detaches, and recursively freezes a version-0.1 manifest.
///
/// This is the only runtime schema composition root for the 0.1 wire model.
/// It intentionally rejects unknown fields and noncanonical identity-array
/// order.
CompiledManifestV01 validateCompiledManifestV01(Object? value, [FormatOptions? options]) {
  try {
    final budgets = resolveFormatBudgets(options);
    final input = record(value, 'manifest');
    exactKeys(input, _topLevelKeys, 'manifest');

    literal(input['formatVersion'], '0.1', 'formatVersion');
    final generator = generatorString(input['generator'], 'generator');
    final canvas = cloneCanvas(input['canvas'], 'canvas');
    final frameRate = cloneFrameRate(input['frameRate'], 'frameRate');
    final renditions = cloneRenditions(input['renditions'], canvas, frameRate, budgets, 'renditions');
    validateRawBlobCount(input['units'], renditions.length, budgets);
    final units = cloneUnits(input['units'], renditions, budgets, 'units');
    final initialState = identifier(input['initialState'], 'initialState');
    final states = cloneStates(input['states'], budgets, 'states');
    final edges = cloneEdges(input['edges'], budgets, 'edges');
    final bindings = cloneBindings(input['bindings'], budgets, 'bindings');
    final readiness = cloneReadiness(input['readiness'], budgets, 'readiness');
    final limits = cloneDeclaredLimits(input['limits'], renditions, canvas, budgets, 'limits');

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

    return CompiledManifestV01(
      generator: generator,
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
