import { watch, type FSWatcher } from "node:fs";
import { lstat } from "node:fs/promises";
import { isAbsolute, join, relative, resolve, sep } from "node:path";

import type { DevCliArguments } from "../cli-args.js";
import { publishCompileBundleDirectory } from "./compile-bundle-publication.js";
import { buildProjectBundleArtifact } from "../compile/project-compiler.js";
import { CompilerError } from "../diagnostics.js";
import type {
  CompileBundleArtifact,
  CompileBundleResult,
  ProjectArtifactOptions
} from "../model.js";
import { resolveProjectWatchPaths } from "./project-input-paths.js";
import { assertDistinctDevOutput } from "./compile-collisions.js";
import {
  createDevServerBuild,
  type DevServerBuild
} from "./dev-server-model.js";

export interface DevBuildEvent {
  readonly sequence: number;
  readonly result: Readonly<CompileBundleResult>;
  /** Exact immutable catalog published to the loopback dev server. */
  readonly build: Readonly<DevServerBuild>;
}

export interface DevFailureEvent {
  readonly sequence: number;
  readonly error: unknown;
}

export interface WatchHandle {
  close(): void;
}

export interface DevCommandDependencies {
  readonly buildProjectBundleArtifact: (
    options: ProjectArtifactOptions
  ) => Promise<Readonly<CompileBundleArtifact>>;
  readonly publishArtifact?: (
    artifact: Readonly<CompileBundleArtifact>,
    context: {
      readonly outputPath: string;
      readonly signal: AbortSignal;
    }
  ) => Promise<Readonly<CompileBundleResult>>;
  readonly watchPath: (path: string, onChange: () => void) => WatchHandle;
}

export interface DevSession {
  /** Settles after the first non-superseded build attempt. */
  readonly firstBuild: Promise<void>;
  /** Settles after close and any active compiler operation has unwound. */
  readonly closed: Promise<void>;
  readonly watchPaths: () => readonly string[];
  close(): Promise<void>;
}

const DEFAULT_DEPENDENCIES: DevCommandDependencies = {
  buildProjectBundleArtifact,
  watchPath: nodeWatchPath
};

/** Start one compile plus a 100 ms, aborting, single-flight local watcher. */
export async function startDevCommand(
  arguments_: DevCliArguments,
  options: {
    readonly cwd: string;
    readonly signal?: AbortSignal;
    readonly debounceMs?: number;
    readonly dependencies?: DevCommandDependencies;
    readonly onBuild?: (event: DevBuildEvent) => void;
    readonly onFailure?: (event: DevFailureEvent) => void;
  }
): Promise<DevSession> {
  if (options.signal?.aborted === true) {
    throw new CompilerError("CANCELLED", "Dev session was cancelled before it started", {
      cause: options.signal.reason
    });
  }
  const projectPath = resolve(options.cwd, arguments_.project);
  const outputPath = resolve(options.cwd, arguments_.output);
  await assertDistinctDevOutput(
    projectPath,
    outputPath,
    arguments_.ffmpegPath,
    arguments_.ffprobePath
  );
  await assertDevBundleDoesNotContainInputs(projectPath, outputPath, [
    ...(arguments_.ffmpegPath === undefined ? [] : [arguments_.ffmpegPath]),
    ...(arguments_.ffprobePath === undefined ? [] : [arguments_.ffprobePath])
  ]);
  const initialOutput = await assertInitialOutput(outputPath, arguments_.force);
  const dependencies = options.dependencies ?? DEFAULT_DEPENDENCIES;
  const defaultPublisher = dependencies.publishArtifact === undefined
    ? createDevPublisher(outputPath, initialOutput)
    : undefined;
  const debounceMs = options.debounceMs ?? 100;
  if (!Number.isSafeInteger(debounceMs) || debounceMs < 0 || debounceMs > 60_000) {
    throw new CompilerError("CLI_USAGE", "Dev debounce must be from 0 through 60,000 ms");
  }

  let currentPaths = await resolveProjectWatchPaths(projectPath);
  let watchers: WatchHandle[] = [];
  let requestedSequence = 1;
  let activeSequence = 0;
  let activeAbort: AbortController | undefined;
  let active: Promise<void> | undefined;
  let debounce: NodeJS.Timeout | undefined;
  let debouncedReady = true;
  let closing = false;
  let firstSettled = false;
  let resolveFirst!: () => void;
  let resolveClosed!: () => void;
  const firstBuild = new Promise<void>((resolvePromise) => {
    resolveFirst = resolvePromise;
  });
  const closed = new Promise<void>((resolvePromise) => {
    resolveClosed = resolvePromise;
  });

  const replaceWatchers = (paths: readonly string[]): void => {
    const replacements: WatchHandle[] = [];
    try {
      for (const path of paths) {
        replacements.push(dependencies.watchPath(path, requestBuild));
      }
    } catch (error) {
      for (const watcher of replacements) watcher.close();
      throw new CompilerError("IO_FAILED", "Could not watch a resolved project input", {
        cause: error
      });
    }
    for (const watcher of watchers) watcher.close();
    currentPaths = Object.freeze([...paths]);
    watchers = replacements;
  };

  const settleFirst = (): void => {
    if (firstSettled) return;
    firstSettled = true;
    resolveFirst();
  };

  const maybeResolveClosed = (): void => {
    if (closing && active === undefined) resolveClosed();
  };

  const compile = async (sequence: number, controller: AbortController): Promise<void> => {
    try {
      const artifact = await dependencies.buildProjectBundleArtifact({
        projectPath,
        ...(arguments_.ffmpegPath === undefined
          ? {}
          : { ffmpegPath: arguments_.ffmpegPath }),
        ...(arguments_.ffprobePath === undefined
          ? {}
          : { ffprobePath: arguments_.ffprobePath }),
        ...(arguments_.mediaTimeoutMs === undefined
          ? {}
          : { mediaTimeoutMs: arguments_.mediaTimeoutMs }),
        signal: controller.signal
      });
      if (closing || sequence !== requestedSequence || controller.signal.aborted) {
        return;
      }
      const build = createDevServerBuild(sequence, artifact);
      const result = dependencies.publishArtifact === undefined
        ? await defaultPublisher!.publish(artifact, controller.signal)
        : await dependencies.publishArtifact(artifact, {
            outputPath,
            signal: controller.signal
          });
      if (!closing && sequence === requestedSequence) {
        options.onBuild?.(Object.freeze({ sequence, result, build }));
        try {
          const nextPaths = await resolveProjectWatchPaths(projectPath);
          if (!closing && sequence === requestedSequence) {
            replaceWatchers(nextPaths);
          }
        } catch (error) {
          if (!closing && sequence === requestedSequence) {
            options.onFailure?.(Object.freeze({ sequence, error }));
          }
        }
        settleFirst();
      }
    } catch (error) {
      if (!closing && sequence === requestedSequence) {
        options.onFailure?.(Object.freeze({ sequence, error }));
        settleFirst();
      }
    }
  };

  const maybeStart = (): void => {
    if (closing || active !== undefined || !debouncedReady) return;
    debouncedReady = false;
    activeSequence = requestedSequence;
    const controller = new AbortController();
    activeAbort = controller;
    const operation = compile(activeSequence, controller);
    active = operation;
    const finalize = (): void => {
      if (active === operation) {
        active = undefined;
        activeAbort = undefined;
      }
      if (!closing && requestedSequence > activeSequence && debounce === undefined) {
        debouncedReady = true;
      }
      maybeStart();
      maybeResolveClosed();
    };
    void operation.then(finalize, finalize);
  };

  function requestBuild(): void {
    if (closing) return;
    requestedSequence += 1;
    activeAbort?.abort(new CompilerError("CANCELLED", "Superseded by a newer source change"));
    debouncedReady = false;
    if (debounce !== undefined) clearTimeout(debounce);
    debounce = setTimeout(() => {
      debounce = undefined;
      debouncedReady = true;
      maybeStart();
    }, debounceMs);
  }

  replaceWatchers(currentPaths);
  const abortFromCaller = (): void => {
    void close();
  };
  options.signal?.addEventListener("abort", abortFromCaller, { once: true });
  if (signalIsAborted(options.signal)) void close();

  async function close(): Promise<void> {
    if (!closing) {
      closing = true;
      options.signal?.removeEventListener("abort", abortFromCaller);
      if (debounce !== undefined) {
        clearTimeout(debounce);
        debounce = undefined;
      }
      for (const watcher of watchers) watcher.close();
      watchers = [];
      activeAbort?.abort(new CompilerError("CANCELLED", "Dev session closed"));
      settleFirst();
      maybeResolveClosed();
    }
    await closed;
  }

  maybeStart();
  return Object.freeze({
    firstBuild,
    closed,
    watchPaths: () => currentPaths,
    close
  });
}

async function assertInitialOutput(
  path: string,
  force: boolean
): Promise<boolean> {
  const metadata = await lstat(path, { bigint: true }).catch(
    (error: NodeJS.ErrnoException) => {
      if (error.code === "ENOENT") return undefined;
      throw new CompilerError("IO_FAILED", "Cannot inspect dev bundle path", {
        path,
        cause: error
      });
    }
  );
  if (metadata === undefined) return false;
  if (metadata.isSymbolicLink()) {
    throw new CompilerError("IO_FAILED", "Refusing symbolic-link dev bundle path", {
      path
    });
  }
  if (!metadata.isDirectory()) {
    throw new CompilerError("IO_FAILED", "Dev output must be a bundle directory", {
      path
    });
  }
  if (!force) {
    throw new CompilerError("IO_FAILED", "Dev output already exists", {
      path,
      hint: "Pass --force to replace this exact local bundle during development."
    });
  }
  return true;
}

function createDevPublisher(
  outputPath: string,
  initiallyExists: boolean
): {
  publish(
    artifact: Readonly<CompileBundleArtifact>,
    signal: AbortSignal
  ): Promise<Readonly<CompileBundleResult>>;
} {
  let replace = initiallyExists;
  return Object.freeze({
    publish: async (artifact, signal) => {
      await publishCompileBundleDirectory(outputPath, {
        assets: artifact.assets.map(({ codec, assetBytes }) => ({
          codec,
          bytes: assetBytes
        })),
        buildReportBytes: artifact.buildReportBytes
      }, { force: replace, signal });
      replace = true;
      return Object.freeze({
        outputPath,
        reportPath: join(outputPath, "build.json"),
        assets: Object.freeze(artifact.buildReport.assets.map((asset) =>
          Object.freeze({ ...asset, path: join(outputPath, asset.path) })
        )),
        provenance: artifact.provenance,
        warnings: artifact.warnings,
        sourceMarkup: artifact.buildReport.sourceMarkup
      });
    }
  });
}

async function assertDevBundleDoesNotContainInputs(
  projectPath: string,
  outputPath: string,
  toolPaths: readonly string[]
): Promise<void> {
  const inputPaths = await resolveProjectWatchPaths(projectPath).catch(() =>
    Object.freeze([projectPath])
  );
  for (const path of [...inputPaths, ...toolPaths]) {
    const relation = relative(outputPath, resolve(path));
    const inside = relation === "" || (
      relation !== ".." &&
      !relation.startsWith(`..${sep}`) &&
      !isAbsolute(relation)
    );
    if (inside) {
      throw new CompilerError(
        "INPUT_INVALID",
        "Dev bundle directory cannot contain a project input or compiler tool",
        { path: outputPath }
      );
    }
  }
}

function nodeWatchPath(path: string, onChange: () => void): FSWatcher {
  const watcher = watch(path, { persistent: true }, () => onChange());
  watcher.on("error", () => onChange());
  return watcher;
}

function signalIsAborted(signal: AbortSignal | undefined): boolean {
  return signal?.aborted === true;
}

export { resolveProjectWatchPaths } from "./project-input-paths.js";
