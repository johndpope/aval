/// Shared H264 subsystem failure helper.
///
/// Dart port of `packages/format/src/h264/failure.ts`.
library;

import '../errors.dart';

/// Port of `h264Invalid` (`failure.ts:3`).
Never h264Invalid(String path, String message, [int? offset]) {
  throw FormatError(
    FormatErrorCode.profileInvalid,
    message,
    FormatErrorDetails(path: path, offset: offset),
  );
}

/// Port of `requireH264` (`failure.ts:13`).
void requireH264(
  bool condition,
  String path,
  String message, [
  int? offset,
]) {
  if (!condition) {
    h264Invalid(path, message, offset);
  }
}
