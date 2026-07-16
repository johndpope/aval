import { FormatError } from "../errors.js";

export function h265Invalid(
  path: string,
  message: string,
  offset?: number
): never {
  throw new FormatError("PROFILE_INVALID", message, {
    path,
    ...(offset === undefined ? {} : { offset })
  });
}

export function requireH265(
  condition: boolean,
  path: string,
  message: string,
  offset?: number
): asserts condition {
  if (!condition) {
    h265Invalid(path, message, offset);
  }
}
