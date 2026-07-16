import { FormatError } from "../errors.js";

export function h264Invalid(
  path: string,
  message: string,
  offset?: number
): never {
  throw new FormatError("PROFILE_INVALID", message, {
    path,
    ...(offset === undefined ? {} : { offset })
  });
}
export function requireH264(
  condition: boolean,
  path: string,
  message: string,
  offset?: number
): asserts condition {
  if (!condition) {
    h264Invalid(path, message, offset);
  }
}
