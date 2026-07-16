import { describe, expect, it } from "vitest";

import * as api from "../src/index.js";

describe("compiler public API", () => {
  it("exposes the supported compile, CLI, validation, and dev boundaries", () => {
    expect(Object.keys(api).sort()).toEqual([
      "COMPILER_PROJECT_VERSION",
      "CompilerError",
      "DEFAULT_PROBE_TIMEOUT_MS",
      "H264_ENCODER_PRESETS",
      "H265_ENCODER_PRESETS",
      "HELP_TEXT",
      "MAX_PROCESS_OUTPUT_BYTES",
      "MAX_PROCESS_STDERR_BYTES",
      "VP9_DEADLINES",
      "bt709LimitedAlphaLuma",
      "bt709LimitedChroma2x2",
      "bt709LimitedLuma",
      "compileDirectInput",
      "compileProjectFile",
      "diagnosticFromError",
      "formatDiagnostic",
      "inspectAssetFile",
      "parseCliArguments",
      "roundSignedRatio",
      "runCli",
      "startDevCommand",
      "unpackAssetFile",
      "validateAssetFile",
      "validateAssetReport"
    ].sort());
  });
});
