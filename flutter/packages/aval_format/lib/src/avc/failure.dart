/// Shared AVC subsystem failure helper.
///
/// Dart port of `packages/format/src/avc/failure.ts`.
library;

import '../errors.dart';

Never avcInvalid(String path, String message, [int? offset]) {
  throw FormatError(
    FormatErrorCode.profileInvalid,
    message,
    FormatErrorDetails(path: path, offset: offset),
  );
}

void requireAvc(
  bool condition,
  String path,
  String message, [
  int? offset,
]) {
  if (!condition) {
    avcInvalid(path, message, offset);
  }
}
