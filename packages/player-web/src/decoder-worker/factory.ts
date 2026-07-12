import { DecoderWorkerClient } from "./client.js";
import {
  DecoderWorkerTransportError,
  normalizeTransportError,
  type DecoderWorkerClientOptions
} from "./client-support.js";
import { type DecoderWorkerClientPort } from "./protocol.js";

export interface OwnedDecoderWorkerPort extends DecoderWorkerClientPort {
  terminate(): void;
}

export type BrowserDecoderWorkerFactory = (
  url: URL,
  options: WorkerOptions
) => OwnedDecoderWorkerPort;

export type DecoderWorkerPortOwner = (
  worker: OwnedDecoderWorkerPort
) => OwnedDecoderWorkerPort;

export interface CreateDecoderWorkerClientOptions
  extends DecoderWorkerClientOptions {
  readonly entryUrl?: URL;
  readonly workerName?: string;
  readonly workerFactory?: BrowserDecoderWorkerFactory;
}

/** Canonical bundler-visible URL for the packaged module-worker entry. */
export function resolveDecoderWorkerEntryUrl(): URL {
  return new URL("./entry.js", import.meta.url);
}

/**
 * Creates the sole owned module Worker and its managed main-thread client.
 * Any setup failure terminates the partially created Worker before escaping.
 */
export function createDecoderWorkerClient(
  options: CreateDecoderWorkerClientOptions = {}
): DecoderWorkerClient {
  return createOwnedDecoderWorkerClient(options, (worker) => worker);
}

/** @internal Allows the browser runtime to wrap and track the default port. */
export function createOwnedDecoderWorkerClient(
  options: CreateDecoderWorkerClientOptions,
  ownWorker: DecoderWorkerPortOwner
): DecoderWorkerClient {
  const workerOptions: WorkerOptions =
    options.workerName === undefined
      ? { type: "module" }
      : { type: "module", name: options.workerName };

  let worker: OwnedDecoderWorkerPort;
  try {
    if (options.workerFactory === undefined && options.entryUrl === undefined) {
      worker = ownCreatedWorker(createPackagedDecoderWorker(options.workerName), ownWorker);
    } else {
      const workerFactory = options.workerFactory ?? defaultWorkerFactory;
      const entryUrl = options.entryUrl ?? resolveDecoderWorkerEntryUrl();
      if (!(entryUrl instanceof URL)) {
        throw new DecoderWorkerTransportError("decoder worker entryUrl must be a URL");
      }
      worker = ownCreatedWorker(workerFactory(entryUrl, workerOptions), ownWorker);
    }
  } catch (error) {
    throw normalizeTransportError(error, "failed to create decoder module worker");
  }

  try {
    return new DecoderWorkerClient(worker, {
      ...(options.disposeTimeoutMs === undefined
        ? {}
        : { disposeTimeoutMs: options.disposeTimeoutMs }),
      ...(options.requestTimeoutMs === undefined
        ? {}
        : { requestTimeoutMs: options.requestTimeoutMs })
    });
  } catch (error) {
    try {
      worker.terminate();
    } catch {
      // Preserve the client-construction failure after best-effort cleanup.
    }
    if (error instanceof Error) {
      throw error;
    }
    throw new DecoderWorkerTransportError(
      "failed to initialize decoder worker client"
    );
  }
}

function ownCreatedWorker(
  created: OwnedDecoderWorkerPort,
  ownWorker: DecoderWorkerPortOwner
): OwnedDecoderWorkerPort {
  try {
    return ownWorker(created);
  } catch (error) {
    try { created.terminate(); } catch { /* Preserve the ownership failure. */ }
    throw error;
  }
}

/** Keep the default Worker and URL expression together for browser bundlers. */
function createPackagedDecoderWorker(workerName: string | undefined): OwnedDecoderWorkerPort {
  return workerName === undefined
    ? new Worker(new URL("./entry.js", import.meta.url), { type: "module" })
    : new Worker(new URL("./entry.js", import.meta.url), { type: "module", name: workerName });
}

function defaultWorkerFactory(
  url: URL,
  options: WorkerOptions
): OwnedDecoderWorkerPort {
  return new Worker(url, options);
}
