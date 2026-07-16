/// Fixed 64-byte version-0.1 format header codec.
///
/// Dart port of `packages/format/src/header.ts`.
library;

import 'dart:typed_data';

import 'checked_integer.dart';
import 'constants.dart';
import 'errors.dart';
import 'model.dart' show FormatHeader, FormatOptions;

class _HeaderFields {
  const _HeaderFields({
    required this.major,
    required this.minor,
    required this.headerLength,
    required this.requiredFeatureFlags,
    required this.declaredFileLength,
    required this.manifestOffset,
    required this.manifestLength,
    required this.indexOffset,
    required this.indexLength,
  });

  final int major;
  final int minor;
  final int headerLength;
  final int requiredFeatureFlags;
  final int declaredFileLength;
  final int manifestOffset;
  final int manifestLength;
  final int indexOffset;
  final int indexLength;
}

Never _fail(String message, int offset) {
  throw FormatError(
    FormatErrorCode.headerInvalid,
    message,
    FormatErrorDetails(offset: offset),
  );
}

void _assertMagic(Uint8List bytes) {
  for (var index = 0; index < formatMagic.length; index += 1) {
    if (bytes[index] != formatMagic[index]) {
      _fail('format magic does not match AVLF 0.1', index);
    }
  }
}

void _validateHeaderShape(_HeaderFields header, [FormatOptions? options]) {
  final budgets = resolveFormatBudgets(options);

  if (header.major != formatVersionMajor || header.minor != formatVersionMinor) {
    throw FormatError(
      FormatErrorCode.versionUnsupported,
      'format version ${header.major}.${header.minor} is unsupported',
      FormatErrorDetails(offset: header.major != formatVersionMajor ? 8 : 10),
    );
  }
  if (header.headerLength != formatHeaderLength) {
    _fail('header length must be $formatHeaderLength', 12);
  }
  if (header.requiredFeatureFlags != 0) {
    throw FormatError(
      FormatErrorCode.featureUnsupported,
      'required feature flags are unsupported in format 0.1',
      const FormatErrorDetails(offset: 16),
    );
  }
  if (header.manifestOffset != formatHeaderLength) {
    _fail('manifest offset must be $formatHeaderLength', 32);
  }
  if (header.manifestLength == 0) {
    _fail('manifest length must be positive', 40);
  }

  int expectedIndexOffset;
  try {
    expectedIndexOffset = align8(
      checkedAdd(formatHeaderLength, header.manifestLength, budgets.maxFileBytes, 'manifest end'),
      budgets.maxFileBytes,
      'index offset',
    );
  } on FormatError catch (error) {
    throw FormatError(error.code, error.message, const FormatErrorDetails(offset: 40));
  } catch (_) {
    _fail('manifest range is invalid', 40);
  }
  if (header.indexOffset != expectedIndexOffset) {
    _fail('index offset must be $expectedIndexOffset', 48);
  }
  if (header.indexLength < accessUnitIndexHeaderLength ||
      (header.indexLength - accessUnitIndexHeaderLength) % accessUnitRecordLength != 0) {
    _fail('index length does not encode whole access-unit records', 56);
  }
  final sampleCount =
      (header.indexLength - accessUnitIndexHeaderLength) ~/ accessUnitRecordLength;
  if (sampleCount > budgets.maxSampleRecords) {
    throw FormatError(
      FormatErrorCode.budgetExceeded,
      'sample record count exceeds the active limit of ${budgets.maxSampleRecords}',
      const FormatErrorDetails(offset: 56),
    );
  }

  int frontIndexEnd;
  try {
    frontIndexEnd =
        checkedAdd(header.indexOffset, header.indexLength, budgets.maxFileBytes, 'front index end');
  } on FormatError catch (error) {
    throw FormatError(error.code, error.message, const FormatErrorDetails(offset: 56));
  } catch (_) {
    _fail('front index range is invalid', 56);
  }
  if (frontIndexEnd > header.declaredFileLength) {
    _fail('front index extends beyond the declared file length', 24);
  }
}

/// Decodes and validates the exact 64-byte version-0.1 header.
FormatHeader parseHeader(Uint8List bytes, [FormatOptions? options]) {
  try {
    requireByteRange(
      bytes,
      0,
      formatHeaderLength,
      FormatErrorCode.headerInvalid,
      'format header',
    );
    _assertMagic(bytes);

    final major = readUint16LE(bytes, 8, FormatErrorCode.headerInvalid, 'major version');
    final minor = readUint16LE(bytes, 10, FormatErrorCode.headerInvalid, 'minor version');
    final headerLength = readUint32LE(bytes, 12, FormatErrorCode.headerInvalid, 'header length');
    final requiredFeatureFlags =
        readUint32LE(bytes, 16, FormatErrorCode.headerInvalid, 'required feature flags');
    final reserved = readUint32LE(bytes, 20, FormatErrorCode.headerInvalid, 'reserved field');
    if (reserved != 0) {
      _fail('reserved header field must be zero', 20);
    }

    final budgets = resolveFormatBudgets(options);
    final declaredFileLength = readUint64LE(
      bytes,
      24,
      budgets.maxFileBytes,
      FormatErrorCode.headerInvalid,
      'declared file length',
    );
    final manifestOffset = readUint64LE(
      bytes,
      32,
      budgets.maxFileBytes,
      FormatErrorCode.headerInvalid,
      'manifest offset',
    );
    final manifestLength = readUint64LE(
      bytes,
      40,
      budgets.maxManifestBytes,
      FormatErrorCode.headerInvalid,
      'manifest length',
    );
    final indexOffset = readUint64LE(
      bytes,
      48,
      budgets.maxFileBytes,
      FormatErrorCode.headerInvalid,
      'index offset',
    );
    final indexLength = readUint64LE(
      bytes,
      56,
      budgets.maxIndexBytes,
      FormatErrorCode.headerInvalid,
      'index length',
    );

    final fields = _HeaderFields(
      major: major,
      minor: minor,
      headerLength: headerLength,
      requiredFeatureFlags: requiredFeatureFlags,
      declaredFileLength: declaredFileLength,
      manifestOffset: manifestOffset,
      manifestLength: manifestLength,
      indexOffset: indexOffset,
      indexLength: indexLength,
    );
    _validateHeaderShape(fields, options);
    return FormatHeader(
      declaredFileLength: declaredFileLength,
      manifestLength: manifestLength,
      indexOffset: indexOffset,
      indexLength: indexLength,
    );
  } on FormatError {
    rethrow;
  } catch (_) {
    throw FormatError(FormatErrorCode.headerInvalid, 'format header could not be parsed');
  }
}

/// Encodes one canonical version-0.1 header into a new 64-byte array.
Uint8List encodeHeader(FormatHeader header, [FormatOptions? options]) {
  try {
    _validateHeaderShape(
      _HeaderFields(
        major: header.major,
        minor: header.minor,
        headerLength: header.headerLength,
        requiredFeatureFlags: header.requiredFeatureFlags,
        declaredFileLength: header.declaredFileLength,
        manifestOffset: header.manifestOffset,
        manifestLength: header.manifestLength,
        indexOffset: header.indexOffset,
        indexLength: header.indexLength,
      ),
      options,
    );
    final bytes = Uint8List(formatHeaderLength);
    bytes.setRange(0, formatMagic.length, formatMagic);
    writeUint16LE(bytes, 8, header.major, FormatErrorCode.headerInvalid, 'major version');
    writeUint16LE(bytes, 10, header.minor, FormatErrorCode.headerInvalid, 'minor version');
    writeUint32LE(bytes, 12, header.headerLength, FormatErrorCode.headerInvalid, 'header length');
    writeUint32LE(
      bytes,
      16,
      header.requiredFeatureFlags,
      FormatErrorCode.headerInvalid,
      'required feature flags',
    );
    writeUint32LE(bytes, 20, 0, FormatErrorCode.headerInvalid, 'reserved field');
    writeUint64LE(
      bytes,
      24,
      header.declaredFileLength,
      FormatErrorCode.headerInvalid,
      'declared file length',
    );
    writeUint64LE(
      bytes,
      32,
      header.manifestOffset,
      FormatErrorCode.headerInvalid,
      'manifest offset',
    );
    writeUint64LE(
      bytes,
      40,
      header.manifestLength,
      FormatErrorCode.headerInvalid,
      'manifest length',
    );
    writeUint64LE(bytes, 48, header.indexOffset, FormatErrorCode.headerInvalid, 'index offset');
    writeUint64LE(bytes, 56, header.indexLength, FormatErrorCode.headerInvalid, 'index length');
    return bytes;
  } on FormatError {
    rethrow;
  } catch (_) {
    throw FormatError(FormatErrorCode.headerInvalid, 'format header could not be encoded');
  }
}

final int minimumCanonicalFileLength = formatHeaderLength + accessUnitIndexHeaderLength;
final int maximumDefaultFileLength = formatDefaultBudgets.maxFileBytes;
