import type {
  ElementOwnershipLedger
} from "./element-ownership-ledger.js";
import { nextElementSequence } from "./element-sequence.js";

export class ElementLifecycle {
  readonly #onConnect: () => void;
  readonly #onDisconnect: () => Promise<void>;
  readonly #onDisconnectFailure: (error: unknown) => void;
  readonly #onDispose: () => Promise<void>;
  readonly #ledger: ElementOwnershipLedger | null;
  #connected = false;
  #disconnectToken = 0;
  #disposed = false;
  #disposeRequested = false;
  #disposal: Promise<void> | null = null;
  #disconnectOperation: Promise<void> = Promise.resolve();
  #disconnectInFlight = 0;

  public constructor(options: Readonly<{
    onConnect(): void;
    onDisconnect(): Promise<void>;
    onDisconnectFailure?(error: unknown): void;
    onDispose(): Promise<void>;
    ledger?: ElementOwnershipLedger;
  }>) {
    this.#onConnect = options.onConnect;
    this.#onDisconnect = options.onDisconnect;
    this.#onDisconnectFailure = options.onDisconnectFailure ?? (() => undefined);
    this.#onDispose = options.onDispose;
    this.#ledger = options.ledger ?? null;
  }

  public get connected(): boolean {
    return this.#connected;
  }

  public get disposed(): boolean {
    return this.#disposed;
  }

  public get terminal(): boolean {
    return this.#disposeRequested;
  }

  public connect(): void {
    if (this.#disposeRequested || this.#connected) return;
    this.#connected = true;
    const token = this.#disconnectToken = nextElementSequence(
      this.#disconnectToken,
      "lifecycle disconnect"
    );
    if (this.#disconnectInFlight === 0) {
      this.#onConnect();
      return;
    }
    void this.#disconnectOperation.then(() => {
      if (
        !this.#disposeRequested &&
        this.#connected &&
        token === this.#disconnectToken
      ) this.#onConnect();
    });
  }

  public disconnect(): void {
    if (this.#disposeRequested || !this.#connected) return;
    const ownership = this.#ledger?.acquire("command") ?? null;
    let token: number;
    try {
      token = this.#disconnectToken = nextElementSequence(
        this.#disconnectToken,
        "lifecycle disconnect"
      );
    } catch (error) {
      ownership?.complete();
      throw error;
    }
    this.#connected = false;
    queueMicrotask(() => {
      if (
        !this.#disposeRequested &&
        !this.#connected &&
        token === this.#disconnectToken
      ) {
        this.#disconnectInFlight += 1;
        const operation = this.#disconnectOperation.then(() => this.#onDisconnect());
        this.#disconnectOperation = operation.catch((error: unknown) => {
          try { this.#onDisconnectFailure(error); } catch {
            // A diagnostic observer is not an ownership boundary.
          }
        }).finally(() => {
          this.#disconnectInFlight = Math.max(0, this.#disconnectInFlight - 1);
          ownership?.complete();
        });
      } else {
        ownership?.complete();
      }
    });
  }

  public dispose(): Promise<void> {
    if (this.#disposal !== null) return this.#disposal;
    this.#disposeRequested = true;
    this.#connected = false;
    this.#disconnectToken = nextElementSequence(
      this.#disconnectToken,
      "lifecycle disconnect"
    );
    const operation = (async () => {
      await this.#disconnectOperation.catch(() => undefined);
      await this.#onDispose();
      this.#disposed = true;
    })();
    this.#disposal = operation;
    void operation.catch(() => {
      if (!this.#disposed && this.#disposal === operation) this.#disposal = null;
    });
    return operation;
  }
}
