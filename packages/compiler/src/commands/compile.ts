import { join, resolve } from "node:path";

import type { CompileCliArguments } from "../cli-args.js";
import {
  buildDirectBundleArtifact,
  buildProjectBundleArtifact
} from "../compile/project-compiler.js";
import { CompilerError } from "../diagnostics.js";
import type {
  CompileBundleArtifact,
  CompileBundleResult,
  DirectArtifactOptions,
  ProjectArtifactOptions
} from "../model.js";
import { publishCompileBundleDirectory } from "./compile-bundle-publication.js";
import { assertDistinctCompileOutputs } from "./compile-collisions.js";

export interface CompileCommandDependencies {
  readonly buildDirectBundleArtifact: (
    options: DirectArtifactOptions
  ) => Promise<Readonly<CompileBundleArtifact>>;
  readonly buildProjectBundleArtifact: (
    options: ProjectArtifactOptions
  ) => Promise<Readonly<CompileBundleArtifact>>;
}

export interface CompileCommandResult extends CompileBundleResult {
  readonly command: "compile";
}

const DEFAULT_DEPENDENCIES: CompileCommandDependencies = {
  buildDirectBundleArtifact,
  buildProjectBundleArtifact
};

/** Build and atomically publish one complete codec bundle directory. */
export async function runCompileCommand(
  arguments_: CompileCliArguments,
  options: {
    readonly cwd: string;
    readonly signal?: AbortSignal;
    readonly dependencies?: CompileCommandDependencies;
  }
): Promise<Readonly<CompileCommandResult>> {
  const dependencies = options.dependencies ?? DEFAULT_DEPENDENCIES;
  const inputPath = resolve(options.cwd, arguments_.input);
  const outputPath = resolve(options.cwd, arguments_.output);
  const reportPath = join(outputPath, "build.json");
  await assertDistinctCompileOutputs(
    arguments_,
    inputPath,
    outputPath,
    reportPath
  );

  const artifact = inputPath.toLowerCase().endsWith(".json")
    ? await dependencies.buildProjectBundleArtifact({
        projectPath: inputPath,
        ...(arguments_.ffmpegPath === undefined
          ? {}
          : { ffmpegPath: arguments_.ffmpegPath }),
        ...(arguments_.ffprobePath === undefined
          ? {}
          : { ffprobePath: arguments_.ffprobePath }),
        ...(arguments_.mediaTimeoutMs === undefined
          ? {}
          : { mediaTimeoutMs: arguments_.mediaTimeoutMs }),
        ...(options.signal === undefined ? {} : { signal: options.signal })
      })
    : await dependencies.buildDirectBundleArtifact(directOptions(
        arguments_,
        inputPath,
        options.signal
      ));

  await publishCompileBundleDirectory(
    outputPath,
    {
      assets: artifact.assets.map(({ codec, assetBytes }) => ({
        codec,
        bytes: assetBytes
      })),
      buildReportBytes: artifact.buildReportBytes
    },
    {
      force: arguments_.force,
      ...(options.signal === undefined ? {} : { signal: options.signal })
    }
  );
  return Object.freeze({
    command: "compile" as const,
    outputPath,
    reportPath,
    assets: Object.freeze(artifact.buildReport.assets.map((asset) =>
      Object.freeze({ ...asset, path: join(outputPath, asset.path) })
    )),
    provenance: artifact.provenance,
    warnings: artifact.warnings,
    sourceMarkup: artifact.buildReport.sourceMarkup
  });
}

function directOptions(
  arguments_: CompileCliArguments,
  inputPath: string,
  signal: AbortSignal | undefined
): DirectArtifactOptions {
  if (arguments_.loop === undefined) {
    throw new CompilerError("CLI_USAGE", "Direct compile requires --loop");
  }
  if (arguments_.codec === undefined) {
    throw new CompilerError("CLI_USAGE", "Direct compile requires --codec");
  }
  const base = {
    inputPath,
    loop: arguments_.loop,
    ...(arguments_.fps === undefined ? {} : { fps: arguments_.fps }),
    normalizeVfr:
      arguments_.normalizeVfr ||
      (arguments_.fps !== undefined && !inputPath.includes("%")),
    ...(arguments_.alpha === undefined ? {} : { alpha: arguments_.alpha }),
    ...(arguments_.ffmpegPath === undefined
      ? {}
      : { ffmpegPath: arguments_.ffmpegPath }),
    ...(arguments_.ffprobePath === undefined
      ? {}
      : { ffprobePath: arguments_.ffprobePath }),
    ...(arguments_.mediaTimeoutMs === undefined
      ? {}
      : { mediaTimeoutMs: arguments_.mediaTimeoutMs }),
    ...(signal === undefined ? {} : { signal }),
    ...(arguments_.canvas === undefined ? {} : { canvas: arguments_.canvas }),
    ...(arguments_.frames === undefined ? {} : { frames: arguments_.frames })
  };
  switch (arguments_.codec) {
    case "h264":
      return Object.freeze({
        ...base,
        codec: arguments_.codec,
        ...(arguments_.crf === undefined ? {} : { crf: arguments_.crf }),
        ...(arguments_.preset === undefined
          ? {}
          : { preset: arguments_.preset })
      });
    case "h265":
      return Object.freeze({
        ...base,
        codec: arguments_.codec,
        ...(arguments_.crf === undefined ? {} : { crf: arguments_.crf }),
        ...(arguments_.preset === undefined
          ? {}
          : { preset: arguments_.preset }),
        ...(arguments_.threads === undefined
          ? {}
          : { threads: arguments_.threads })
      });
    case "vp9":
      return Object.freeze({
        ...base,
        codec: arguments_.codec,
        ...(arguments_.crf === undefined ? {} : { crf: arguments_.crf }),
        ...(arguments_.deadline === undefined
          ? {}
          : { deadline: arguments_.deadline }),
        ...(arguments_.cpuUsed === undefined
          ? {}
          : { cpuUsed: arguments_.cpuUsed }),
        ...(arguments_.threads === undefined
          ? {}
          : { threads: arguments_.threads })
      });
    case "av1":
      return Object.freeze({
        ...base,
        codec: arguments_.codec,
        ...(arguments_.crf === undefined ? {} : { crf: arguments_.crf }),
        ...(arguments_.bitDepth === undefined
          ? {}
          : { bitDepth: arguments_.bitDepth }),
        ...(arguments_.cpuUsed === undefined
          ? {}
          : { cpuUsed: arguments_.cpuUsed }),
        ...(arguments_.tiles === undefined
          ? {}
          : { tiles: arguments_.tiles }),
        rowMt: arguments_.rowMt,
        ...(arguments_.threads === undefined
          ? {}
          : { threads: arguments_.threads })
      });
  }
}
