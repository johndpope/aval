// Dart port of packages/format/test/manifest-fixture.ts.
//
// Builds untyped Map/List manifest trees (matching how the TS fixture
// builds plain JSON-shaped object literals) suitable as input to
// `validateCompiledManifestV01`.
library;

final String _digest = '0'.padRight(64, '0');

String _numbered(String prefix, int index) => '$prefix-${index.toString().padLeft(2, '0')}';

Map<String, Object?> _sample(int sampleStart, int sampleCount) =>
    {'rendition': 'reference', 'sampleStart': sampleStart, 'sampleCount': sampleCount, 'sha256': _digest};

Map<String, Object?> _body(
  String id,
  String playback,
  int frameCount,
  List<int> portalFrames,
  int sampleStart,
) =>
    {
      'id': id,
      'kind': 'body',
      'playback': playback,
      'frameCount': frameCount,
      'ports': [
        {'id': 'default', 'entryFrame': 0, 'portalFrames': portalFrames},
      ],
      'samples': [_sample(sampleStart, frameCount)],
    };

Map<String, Object?> _basicUnit(String id, String kind, int frameCount, int sampleStart) => {
      'id': id,
      'kind': kind,
      'frameCount': frameCount,
      'samples': [_sample(sampleStart, frameCount)],
    };

/// A fresh compact manifest covering every graph-bearing 0.1 unit kind.
Map<String, Object?> validManifest() => {
      'formatVersion': '0.1',
      'generator': 'aval-tests',
      'canvas': {
        'width': 2,
        'height': 2,
        'fit': 'contain',
        'pixelAspect': [1, 1],
        'colorSpace': 'srgb',
      },
      'frameRate': {'numerator': 30, 'denominator': 1},
      'renditions': [
        {
          'id': 'reference',
          'profile': 'reference-rgba-v0',
          'codec': 'aval.reference-rgba',
          'codedWidth': 2,
          'codedHeight': 2,
          'alphaLayout': {'type': 'straight-rgba-v0'},
          'capabilities': <String>[],
        },
      ],
      'units': [
        _body('body-a', 'loop', 4, [0, 2], 0),
        _body('body-b', 'finite', 3, [2], 4),
        _body('body-c', 'finite', 1, [0], 7),
        _basicUnit('bridge-ab', 'bridge', 2, 8),
        _basicUnit('intro-a', 'one-shot', 2, 10),
        {
          'id': 'rev-bc',
          'kind': 'reversible',
          'frameCount': 6,
          'residency': {
            'endpoints': [
              {'state': 'a-b', 'port': 'default', 'frames': 6},
              {'state': 'a-c', 'port': 'default', 'frames': 6},
            ],
          },
          'samples': [_sample(12, 6)],
        },
      ],
      'initialState': 'a-a',
      'states': [
        {'id': 'a-a', 'bodyUnit': 'body-a', 'initialUnit': 'intro-a'},
        {'id': 'a-b', 'bodyUnit': 'body-b'},
        {'id': 'a-c', 'bodyUnit': 'body-c'},
      ],
      'edges': [
        {
          'id': 'edge-ab',
          'from': 'a-a',
          'to': 'a-b',
          'trigger': {'type': 'event', 'name': 'go-b'},
          'start': {
            'type': 'portal',
            'sourcePort': 'default',
            'targetPort': 'default',
            'maxWaitFrames': 1,
          },
          'transition': {'kind': 'locked', 'unit': 'bridge-ab'},
          'continuity': 'exact-authored',
        },
        {
          'id': 'edge-ac',
          'from': 'a-a',
          'to': 'a-c',
          'trigger': {'type': 'event', 'name': 'go-c'},
          'start': {'type': 'cut', 'targetPort': 'default', 'maxWaitFrames': 1},
          'continuity': 'cut',
          'targetRunwayFrames': 6,
        },
        {
          'id': 'edge-ba',
          'from': 'a-b',
          'to': 'a-a',
          'trigger': {'type': 'completion'},
          'start': {'type': 'finish', 'targetPort': 'default', 'maxWaitFrames': 2},
          'continuity': 'exact-authored',
        },
        {
          'id': 'edge-bc',
          'from': 'a-b',
          'to': 'a-c',
          'trigger': {'type': 'event', 'name': 'go-c'},
          'start': {
            'type': 'portal',
            'sourcePort': 'default',
            'targetPort': 'default',
            'maxWaitFrames': 2,
          },
          'transition': {'kind': 'reversible', 'unit': 'rev-bc', 'direction': 'forward'},
          'continuity': 'exact-authored',
        },
        {
          'id': 'edge-cb',
          'from': 'a-c',
          'to': 'a-b',
          'trigger': {'type': 'event', 'name': 'go-b'},
          'start': {
            'type': 'portal',
            'sourcePort': 'default',
            'targetPort': 'default',
            'maxWaitFrames': 0,
          },
          'transition': {
            'kind': 'reversible',
            'unit': 'rev-bc',
            'direction': 'reverse',
            'reverseOf': 'edge-bc',
          },
          'continuity': 'exact-reverse',
        },
      ],
      'bindings': [
        {'source': 'activate', 'event': 'go-c'},
        {'source': 'pointer.enter', 'event': 'go-b'},
      ],
      'readiness': {
        'policy': 'all-routes',
        'bootstrapUnits': ['body-a', 'body-b', 'body-c', 'bridge-ab', 'intro-a'],
        'immediateEdges': ['edge-ab', 'edge-ac'],
      },
      'limits': {
        'maxCompiledBytes': 32 * 1024,
        'maxRuntimeBytes': 64 * 1024,
        'decodedPixelBytes': 16,
        'persistentCacheBytes': 0,
        'runtimeWorkingSetBytes': 16,
      },
    };

/// A valid manifest exactly at the state/edge/unit/blob/frame ceilings.
Map<String, Object?> limitManifest() {
  final bodyUnits = List<Map<String, Object?>>.generate(32, (index) {
    return {
      'id': _numbered('body', index),
      'kind': 'body',
      'playback': 'finite',
      'frameCount': 1,
      'ports': [
        {'id': 'default', 'entryFrame': 0, 'portalFrames': [0]},
      ],
      'samples': <Map<String, Object?>>[],
    };
  });
  final bridgeUnits = List<Map<String, Object?>>.generate(64, (index) {
    return {
      'id': _numbered('bridge', index),
      'kind': 'bridge',
      'frameCount': index < 36 ? 14 : 13,
      'samples': <Map<String, Object?>>[],
    };
  });
  final units = [...bodyUnits, ...bridgeUnits];
  var sampleStart = 0;
  for (final unit in units) {
    final frameCount = unit['frameCount'] as int;
    (unit['samples'] as List<Map<String, Object?>>).add({
      'rendition': 'reference',
      'sampleStart': sampleStart,
      'sampleCount': frameCount,
      'sha256': _digest,
    });
    sampleStart += frameCount;
  }

  final states = List<Map<String, Object?>>.generate(32, (index) {
    return {'id': _numbered('state', index), 'bodyUnit': _numbered('body', index)};
  });
  final edges = List<Map<String, Object?>>.generate(64, (index) {
    final from = index % 32;
    final targetStep = index < 32 ? 1 : 2;
    return {
      'id': _numbered('edge', index),
      'from': _numbered('state', from),
      'to': _numbered('state', (from + targetStep) % 32),
      'start': {
        'type': 'portal',
        'sourcePort': 'default',
        'targetPort': 'default',
        'maxWaitFrames': 0,
      },
      'transition': {'kind': 'locked', 'unit': _numbered('bridge', index)},
      'continuity': 'exact-authored',
    };
  });

  return {
    'formatVersion': '0.1',
    'generator': 'aval-limit-tests',
    'canvas': {
      'width': 2,
      'height': 2,
      'fit': 'contain',
      'pixelAspect': [1, 1],
      'colorSpace': 'srgb',
    },
    'frameRate': {'numerator': 60, 'denominator': 1},
    'renditions': [
      {
        'id': 'reference',
        'profile': 'reference-rgba-v0',
        'codec': 'aval.reference-rgba',
        'codedWidth': 2,
        'codedHeight': 2,
        'alphaLayout': {'type': 'straight-rgba-v0'},
        'capabilities': <String>[],
      },
    ],
    'units': units,
    'initialState': 'state-00',
    'states': states,
    'edges': edges,
    'bindings': <Map<String, Object?>>[],
    'readiness': {
      'policy': 'all-routes',
      'bootstrapUnits': ['body-00', 'body-01', 'body-02', 'bridge-00', 'bridge-32'],
      'immediateEdges': ['edge-00', 'edge-32'],
    },
    'limits': {
      'maxCompiledBytes': 32 * 1024 * 1024,
      'maxRuntimeBytes': 64 * 1024 * 1024,
      'decodedPixelBytes': 16,
      'persistentCacheBytes': 0,
      'runtimeWorkingSetBytes': 16,
    },
  };
}
