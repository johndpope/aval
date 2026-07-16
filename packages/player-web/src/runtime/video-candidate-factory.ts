import type {
  IntegratedCandidateAttempt,
  IntegratedCandidateAttemptContext,
  IntegratedCandidateFactory
} from "./integrated-player-contracts.js";
import { VideoCandidateAttempt } from "./video-candidate-attempt.js";
import type {
  VideoCandidateFactoryOptions,
  VideoCandidateResourceAuthority,
  VideoCandidateResourcePlanLease
} from "./video-candidate-model.js";
import { validateVideoCandidateFactoryOptions } from "./video-candidate-support.js";
import { validateVideoCandidateAttemptContext } from "./video-candidate-validation.js";
import { captureRuntimeCanvasResourceHost } from "./canvas-resource-plan.js";
import type { BrowserContextRecoveryEventTarget } from "./browser-context-recovery.js";
import type { RuntimeResourceAllocationSnapshot } from "./resource-plan.js";

export type {
  VideoCandidateWorkerSetup,
  VideoCandidateActivationInput,
  VideoCandidateCachePreparer,
  VideoCandidateFactoryOptions,
  VideoCandidatePreparedMedia,
  VideoCandidateResourceAuthority,
  VideoCandidateResourcePlanLease,
  VideoCandidateResourcePlanLeaseSnapshot,
  VideoCandidateReadinessFactory,
  VideoCandidateReadinessSession,
  VideoCandidateReadinessSessionInput,
  VideoCandidateRendererFactory,
  VideoCandidateRendererReservation,
  VideoCandidateTimerHost,
  VideoCandidateWorker,
  VideoCandidateWorkerFactory
} from "./video-candidate-model.js";
export { createVideoCandidateWorkerSetup } from "./video-candidate-config.js";

/**
 * Concrete profile-neutral video composition root. Effects stay injected, while ordering,
 * budgets, generations, the sole readiness run, and ownership stay here.
 */
export class VideoCandidateFactory implements IntegratedCandidateFactory {
  readonly #options: Readonly<VideoCandidateFactoryOptions>;
  #workerOwner: symbol | null = null;

  public readonly availability: IntegratedCandidateFactory["availability"];
  public readonly resourceHost?: NonNullable<
    IntegratedCandidateFactory["resourceHost"]
  >;
  public readonly contextTarget?: NonNullable<
    IntegratedCandidateFactory["contextTarget"]
  >;

  public constructor(options: Readonly<VideoCandidateFactoryOptions>) {
    const capturedOptions = captureVideoCandidateFactoryOptions(options);
    validateVideoCandidateFactoryOptions(capturedOptions);
    this.#options = capturedOptions;
    if (capturedOptions.resourceHost !== undefined) {
      this.resourceHost = capturedOptions.resourceHost;
    }
    if (capturedOptions.contextTarget !== undefined) {
      this.contextTarget = capturedOptions.contextTarget;
    }
    this.availability = Object.freeze({
      workerAvailable: capturedOptions.workerFactory.available,
      rendererAvailable: capturedOptions.rendererFactory.available
    });
  }

  public create(
    context: Readonly<IntegratedCandidateAttemptContext>
  ): IntegratedCandidateAttempt {
    validateVideoCandidateAttemptContext(context);
    const owner = Symbol("video-candidate-attempt");
    return new VideoCandidateAttempt({
      context,
      factoryOptions: this.#options,
      owner,
      acquireWorker: () => {
        if (this.#workerOwner !== null) {
          throw new RangeError(
            "only one video candidate decoder worker may be alive"
          );
        }
        this.#workerOwner = owner;
      },
      releaseWorker: () => {
        if (this.#workerOwner === owner) this.#workerOwner = null;
      }
    });
  }
}

function captureVideoCandidateFactoryOptions(
  options: Readonly<VideoCandidateFactoryOptions>
): Readonly<VideoCandidateFactoryOptions> {
  if (options === null || typeof options !== "object") {
    throw new TypeError("video candidate factory options must be an object");
  }
  const workerFactory = options.workerFactory;
  const rendererFactory = options.rendererFactory;
  const readinessFactory = options.readinessFactory;
  const clock = options.clock;
  const timers = options.timers;
  const prepareCache = options.prepareCache;
  const rawResourceHost = options.resourceHost;
  const rawContextTarget = options.contextTarget;
  const rawResourceAuthority = options.resourceAuthority;
  const resourceHost = rawResourceHost === undefined
    ? undefined
    : captureRuntimeCanvasResourceHost(rawResourceHost);
  const resourceAuthority = rawResourceAuthority === undefined
    ? undefined
    : captureVideoCandidateResourceAuthority(rawResourceAuthority);
  const contextTarget = rawContextTarget === undefined
    ? undefined
    : captureContextTarget(rawContextTarget);
  return Object.freeze({
    workerFactory,
    rendererFactory,
    readinessFactory,
    ...(resourceHost === undefined ? {} : { resourceHost }),
    ...(contextTarget === undefined ? {} : { contextTarget }),
    ...(resourceAuthority === undefined ? {} : { resourceAuthority }),
    ...(clock === undefined ? {} : { clock }),
    ...(timers === undefined ? {} : { timers }),
    ...(prepareCache === undefined ? {} : { prepareCache })
  });
}

function captureContextTarget(
  value: BrowserContextRecoveryEventTarget
): BrowserContextRecoveryEventTarget {
  if (value === null || typeof value !== "object") {
    throw new TypeError("video candidate context target is malformed");
  }
  let add: unknown;
  let remove: unknown;
  try {
    add = Reflect.get(value, "addEventListener");
    remove = Reflect.get(value, "removeEventListener");
  } catch {
    throw new TypeError("video candidate context target is inaccessible");
  }
  if (typeof add !== "function" || typeof remove !== "function") {
    throw new TypeError("video candidate context target is malformed");
  }
  return Object.freeze({
    addEventListener: (
      type: "webglcontextlost" | "webglcontextrestored",
      listener: Parameters<BrowserContextRecoveryEventTarget["addEventListener"]>[1]
    ) => {
      Reflect.apply(add, value, [type, listener]);
    },
    removeEventListener: (
      type: "webglcontextlost" | "webglcontextrestored",
      listener: Parameters<BrowserContextRecoveryEventTarget["removeEventListener"]>[1]
    ) => {
      Reflect.apply(remove, value, [type, listener]);
    }
  });
}

function captureVideoCandidateResourceAuthority(
  value: VideoCandidateResourceAuthority
): VideoCandidateResourceAuthority {
  if (value === null || typeof value !== "object") {
    throw new TypeError("video candidate resource authority is malformed");
  }
  let reservePlan: unknown;
  let requestDecoder: unknown;
  try {
    reservePlan = Reflect.get(value, "reservePlan");
    requestDecoder = Reflect.get(value, "requestDecoder");
  } catch {
    throw new TypeError("video candidate resource authority is inaccessible");
  }
  if (typeof reservePlan !== "function" || typeof requestDecoder !== "function") {
    throw new TypeError("video candidate resource authority is malformed");
  }
  return Object.freeze({
    reservePlan: (allocation: Readonly<RuntimeResourceAllocationSnapshot>) => Reflect.apply(
      reservePlan,
      value,
      [allocation]
    ) as VideoCandidateResourcePlanLease,
    requestDecoder: () => Reflect.apply(
      requestDecoder,
      value,
      []
    ) as ReturnType<
      VideoCandidateResourceAuthority["requestDecoder"]
    >
  });
}
