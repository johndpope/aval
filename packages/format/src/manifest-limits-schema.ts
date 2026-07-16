import { checkedMultiply } from "./checked-integer.js";
import { FormatError } from "./errors.js";
import {
  exactKeys,
  integerInRange,
  invalid,
  positiveInteger,
  record
} from "./manifest-validation.js";
import type {
  DeclaredLimits,
  FormatBudgets,
  ProductionRendition
} from "./model.js";

export function cloneDeclaredLimits(
  value: unknown,
  renditions: readonly ProductionRendition[],
  budgets: FormatBudgets,
  path: string
): DeclaredLimits {
  const input = record(value, path);
  exactKeys(
    input,
    [
      "maxCompiledBytes",
      "maxRuntimeBytes",
      "decodedPixelBytes",
      "persistentCacheBytes",
      "runtimeWorkingSetBytes"
    ],
    path
  );
  const maxCompiledBytes = positiveInteger(
    input.maxCompiledBytes,
    `${path}.maxCompiledBytes`
  );
  if (maxCompiledBytes > budgets.maxFileBytes) {
    throw new FormatError(
      "BUDGET_EXCEEDED",
      `maxCompiledBytes exceeds the active limit of ${String(budgets.maxFileBytes)}`,
      { path: `${path}.maxCompiledBytes` }
    );
  }
  const maxRuntimeBytes = positiveInteger(input.maxRuntimeBytes, `${path}.maxRuntimeBytes`);
  const decodedPixelBytes = integerInRange(
    input.decodedPixelBytes,
    `${path}.decodedPixelBytes`,
    0,
    maxRuntimeBytes
  );
  const persistentCacheBytes = integerInRange(
    input.persistentCacheBytes,
    `${path}.persistentCacheBytes`,
    0,
    maxRuntimeBytes
  );
  const runtimeWorkingSetBytes = integerInRange(
    input.runtimeWorkingSetBytes,
    `${path}.runtimeWorkingSetBytes`,
    0,
    maxRuntimeBytes
  );
  if (
    runtimeWorkingSetBytes < decodedPixelBytes ||
    runtimeWorkingSetBytes < persistentCacheBytes
  ) {
    invalid(
      `${path}.runtimeWorkingSetBytes`,
      "must be at least decodedPixelBytes and persistentCacheBytes"
    );
  }
  const minimumDecodedBytes = Math.max(
    ...renditions.map((rendition, index) =>
      checkedMultiply(
        checkedMultiply(
          rendition.codedWidth,
          rendition.codedHeight,
          Number.MAX_SAFE_INTEGER,
          `renditions[${String(index)}] coded pixel count`
        ),
        4,
        Number.MAX_SAFE_INTEGER,
        `renditions[${String(index)}] decoded RGBA bytes`
      )
    )
  );
  if (decodedPixelBytes < minimumDecodedBytes) {
    invalid(
      `${path}.decodedPixelBytes`,
      `must be at least ${String(minimumDecodedBytes)}`
    );
  }
  return Object.freeze({
    maxCompiledBytes,
    maxRuntimeBytes,
    decodedPixelBytes,
    persistentCacheBytes,
    runtimeWorkingSetBytes
  });
}
