/// Strict, occurrence-aware AVC inspection for worker decode submission.
///
/// The instance retains only numbers, strings, frozen parsed syntax, and a
/// parameter-set byte signature string. Caller-owned byte views are consumed
/// synchronously and never retained. A failed inspection does not advance
/// the unit or picture-order state.
///
/// Dart port of `packages/format/src/avc/incremental-inspector.ts`.
library;

import '../checked_integer.dart' show maxSafeInteger;
import '../constants.dart' show formatDefaultBudgets, identifierPattern;
import '../errors.dart';
import 'failure.dart';
import 'inspector.dart';
import 'types.dart';

class _ActiveUnitState {
  const _ActiveUnitState({
    required this.unitId,
    required this.unitInstance,
    required this.unitFrameCount,
    required this.nextUnitFrame,
    required this.pictureOrder,
  });

  final String unitId;
  final int unitInstance;
  final int unitFrameCount;
  final int nextUnitFrame;
  final AvcPictureOrderState pictureOrder;
}

class AvcIncrementalInspector {
  AvcIncrementalInspector(AvcConstrainedBaselineProfile profile)
      : _profile = _initProfile(profile);

  static AvcConstrainedBaselineProfile _initProfile(
    AvcConstrainedBaselineProfile profile,
  ) {
    try {
      return cloneAvcProfile(profile);
    } on FormatError {
      rethrow;
    } catch (_) {
      throw FormatError(
        FormatErrorCode.profileInvalid,
        'incremental AVC profile could not be read',
      );
    }
  }

  final AvcConstrainedBaselineProfile _profile;
  AvcParameterSetState? _stableParameterSets;
  AvcParameterSetSummary? _parameterSetSummary;
  int? _macroblocksPerFrame;
  _ActiveUnitState? _activeUnit;
  int _maximumUnitInstance = -1;

  AvcParameterSetSummary? get parameterSet => _parameterSetSummary;

  int? get macroblocksPerFrame => _macroblocksPerFrame;

  /// Inspects one access unit and advances state only after every check
  /// passes.
  AvcIncrementalAccessUnitInspection inspect(
    AvcIncrementalAccessUnitInput input,
  ) {
    try {
      _validateIncrementalInput(input);
      final previous = _activeUnit;
      _validateUnitSequence(input, previous, _maximumUnitInstance);

      final pictureOrder = previous == null
          ? createAvcPictureOrderState()
          : cloneAvcPictureOrderState(previous.pictureOrder);
      final result = inspectAvcAccessUnitStatefully(
        input,
        input.unitFrame,
        _incrementalPath(input),
        _stableParameterSets,
        _stableParameterSets,
        _profile,
        pictureOrder,
        _macroblocksPerFrame,
      );
      var stableParameterSets = _stableParameterSets;
      var parameterSetSummary = _parameterSetSummary;
      var macroblocksPerFrame = _macroblocksPerFrame;
      if (stableParameterSets == null) {
        stableParameterSets = result.parameterSets;
        macroblocksPerFrame = validateAvcSpsAgainstProfile(
          stableParameterSets.sps,
          _profile,
          '${_incrementalPath(input)}.sps',
        );
        parameterSetSummary = createAvcParameterSetSummary(
          stableParameterSets.sps,
        );
      }

      final nextUnitFrame = input.unitFrame + 1;
      final unitComplete = nextUnitFrame == input.unitFrameCount;
      _stableParameterSets = stableParameterSets;
      _parameterSetSummary = parameterSetSummary;
      _macroblocksPerFrame = macroblocksPerFrame;
      _maximumUnitInstance = _maximumUnitInstance > input.unitInstance
          ? _maximumUnitInstance
          : input.unitInstance;
      _activeUnit = unitComplete
          ? null
          : _ActiveUnitState(
              unitId: input.unitId,
              unitInstance: input.unitInstance,
              unitFrameCount: input.unitFrameCount,
              nextUnitFrame: nextUnitFrame,
              pictureOrder: pictureOrder,
            );

      return AvcIncrementalAccessUnitInspection(
        unitId: input.unitId,
        unitInstance: input.unitInstance,
        unitFrame: input.unitFrame,
        unitFrameCount: input.unitFrameCount,
        unitComplete: unitComplete,
        chunkType: result.summary.idr ? 'key' : 'delta',
        accessUnit: result.summary,
      );
    } on FormatError {
      rethrow;
    } catch (_) {
      throw FormatError(
        FormatErrorCode.profileInvalid,
        'incremental AVC access unit could not be inspected',
      );
    }
  }

  /// Starts a new generation while preserving rendition parameter identity.
  /// The next accepted sample must still be frame-zero SPS/PPS/IDR.
  void resetUnitSequence() {
    _activeUnit = null;
    _maximumUnitInstance = -1;
  }
}

void _validateIncrementalInput(AvcIncrementalAccessUnitInput input) {
  requireAvc(
    identifierPattern.hasMatch(input.unitId),
    'sample.unitId',
    'unit id is invalid',
  );
  requireAvc(
    input.unitInstance >= 0 && input.unitInstance <= maxSafeInteger,
    'sample.unitInstance',
    'unit instance must be a nonnegative safe integer',
  );
  requireAvc(
    input.unitFrameCount > 0 &&
        input.unitFrameCount <= formatDefaultBudgets.maxTotalUnitFrames,
    'sample.unitFrameCount',
    'unit frame count is outside the format budget',
  );
  requireAvc(
    input.unitFrame >= 0 && input.unitFrame < input.unitFrameCount,
    'sample.unitFrame',
    'unit frame lies outside the unit',
  );
  validateAvcAccessUnitInput(input, 'sample');
}

void _validateUnitSequence(
  AvcIncrementalAccessUnitInput input,
  _ActiveUnitState? active,
  int maximumUnitInstance,
) {
  if (active == null) {
    requireAvc(
      input.unitFrame == 0,
      'sample.unitFrame',
      'a unit instance must begin with frame zero',
    );
    requireAvc(
      input.unitInstance > maximumUnitInstance,
      'sample.unitInstance',
      'unit instances must increase monotonically',
    );
    return;
  }
  requireAvc(
    input.unitId == active.unitId &&
        input.unitInstance == active.unitInstance &&
        input.unitFrameCount == active.unitFrameCount &&
        input.unitFrame == active.nextUnitFrame,
    'sample',
    'unit-instance samples must be contiguous and internally consistent',
  );
}

String _incrementalPath(AvcIncrementalAccessUnitInput input) =>
    'units.${input.unitId}.${input.unitInstance}[${input.unitFrame}]';
