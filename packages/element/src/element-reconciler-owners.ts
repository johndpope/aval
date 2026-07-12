import type {
  ElementAssetGeneration,
  ElementBrowserRuntimeFactory
} from "./asset-generation.js";
import type { ElementCommandSlot } from "./element-command-slot.js";
import { ElementController } from "./element-controller.js";
import {
  ElementConfigurationScheduler,
  type ElementConfigurationAuthority
} from "./element-configuration-scheduler.js";
import type { ElementDesiredSnapshot } from "./element-desired-state.js";
import { ElementFailures } from "./element-failures.js";
import type { ElementAutomaticPrepareAuthority } from "./element-generation-factory.js";
import { ElementGenerationFactory } from "./element-generation-factory.js";
import type { ElementAssetPublicationAuthority } from "./element-generation-publication.js";
import {
  ElementHostAutomation,
  type ElementAutomationAuthority
} from "./element-host-automation.js";
import { ElementLifecycle } from "./element-lifecycle.js";
import type { ElementOwnershipLedger } from "./element-ownership-ledger.js";
import { ElementPublicEvents } from "./element-public-events.js";
import type { ElementPublicState } from "./element-public-state.js";
import { ElementReconcileLane } from "./element-reconcile-lane.js";
import {
  ElementRuntimeEffects,
  type ElementResumeCommandKey,
  type ElementStateCommandKey
} from "./element-runtime-effects.js";
import type { ElementTrace } from "./element-trace.js";
import { ShadowLayerOwner } from "./shadow-layers.js";

export interface ElementOwnerAuthority extends
  ElementAssetPublicationAuthority,
  ElementAutomaticPrepareAuthority,
  ElementAutomationAuthority,
  ElementConfigurationAuthority {
  ownerFailureContext(): Readonly<{
    terminal: boolean;
    connected: boolean;
    activeSource: boolean;
    sourceGeneration: number;
  }>;
  ownerCreateGeneration(generation: number): ElementAssetGeneration | null;
  ownerSourceRetired(): void;
  ownerReconcile(snapshot: Readonly<ElementDesiredSnapshot>): Promise<void>;
  ownerConnect(): void;
  ownerDisconnect(): Promise<void>;
  ownerDisconnectFailure(error: unknown): void;
  ownerDispose(): Promise<void>;
}

/** Dependency assembly only; all callbacks re-enter ElementReconciler. */
export class ElementReconcilerOwners {
  public readonly layers: ShadowLayerOwner;
  public readonly events: ElementPublicEvents;
  public readonly failures: ElementFailures;
  public readonly automation: ElementHostAutomation;
  public readonly configuration: ElementConfigurationScheduler;
  public readonly effects: ElementRuntimeEffects;
  public readonly generationFactory: ElementGenerationFactory;
  public readonly controller: ElementController;
  public readonly lane: ElementReconcileLane<Readonly<ElementDesiredSnapshot>>;
  public readonly lifecycle: ElementLifecycle;

  public constructor(input: Readonly<{
    host: HTMLElement;
    ownership: ElementOwnershipLedger;
    state: ElementPublicState;
    trace: ElementTrace;
    stateCommand: ElementCommandSlot<ElementStateCommandKey>;
    resumeCommand: ElementCommandSlot<ElementResumeCommandKey>;
    authority: ElementOwnerAuthority;
    factory?: ElementBrowserRuntimeFactory;
  }>) {
    this.layers = new ShadowLayerOwner(input.host);
    this.events = new ElementPublicEvents(input.host);
    this.failures = new ElementFailures({
      events: this.events,
      state: input.state,
      layers: this.layers,
      context: () => input.authority.ownerFailureContext()
    });
    this.automation = new ElementHostAutomation({
      host: input.host,
      ledger: input.ownership,
      authority: input.authority
    });
    this.configuration = new ElementConfigurationScheduler({
      host: input.host,
      ledger: input.ownership,
      authority: input.authority
    });
    this.effects = new ElementRuntimeEffects({
      layers: this.layers,
      router: this.automation.router,
      inputs: this.automation.inputs,
      state: input.state,
      stateCommand: input.stateCommand,
      resumeCommand: input.resumeCommand
    });
    this.generationFactory = new ElementGenerationFactory({
      host: input.host,
      layers: this.layers,
      events: this.events,
      state: input.state,
      failures: this.failures,
      ledger: input.ownership,
      trace: input.trace,
      publicationAuthority: input.authority,
      prepareAuthority: input.authority,
      ...(input.factory === undefined ? {} : { factory: input.factory })
    });
    this.controller = new ElementController({
      create: (generation) => input.authority.ownerCreateGeneration(generation),
      onRetired: () => input.authority.ownerSourceRetired()
    });
    this.lane = new ElementReconcileLane(
      (snapshot) => input.authority.ownerReconcile(snapshot),
      input.ownership
    );
    this.lifecycle = new ElementLifecycle({
      ledger: input.ownership,
      onConnect: () => input.authority.ownerConnect(),
      onDisconnect: () => input.authority.ownerDisconnect(),
      onDisconnectFailure: (error) => input.authority.ownerDisconnectFailure(error),
      onDispose: () => input.authority.ownerDispose()
    });
    this.configuration.schedule();
  }
}
