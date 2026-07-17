/// Shared HEVC (H.265) subsystem failure helper.
///
/// Dart port of `packages/format/src/h265/failure.ts`.
library;

import '../errors.dart';

/// Throws a `PROFILE_INVALID` [FormatError] for the HEVC subsystem.
///
/// Port of `h265Invalid` (`src/h265/failure.ts:3`).
Never h265Invalid(String path, String message, [int? offset]) {
  throw FormatError(
    FormatErrorCode.profileInvalid,
    message,
    FormatErrorDetails(path: path, offset: offset),
  );
}

/// Asserts [condition], otherwise fails via [h265Invalid].
///
/// Port of `requireH265` (`src/h265/failure.ts:14`).
void requireH265(
  bool condition,
  String path,
  String message, [
  int? offset,
]) {
  if (!condition) {
    h265Invalid(path, message, offset);
  }
}
