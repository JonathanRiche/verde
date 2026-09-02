import type { EndpointProvider } from "./endpoint_provider.ts";
import type { ControlPlaneStore } from "./store.ts";

type CleanupStore = Pick<
  ControlPlaneStore,
  "claimProviderCleanup" | "completeProviderCleanup" | "retryProviderCleanup"
>;

type CleanupProvider = Pick<EndpointProvider, "removeLink" | "removeEnrollment" | "reconcileLink">;

/** Runs the durable provider-cleanup outbox without overlapping polls in one process. */
export class ProviderCleanupRunner {
  readonly #store: CleanupStore;
  readonly #provider: CleanupProvider;
  readonly #requestDeadlineMs: number;
  #running: Promise<void> | null = null;

  constructor(store: CleanupStore, provider: CleanupProvider, requestDeadlineMs: number) {
    this.#store = store;
    this.#provider = provider;
    this.#requestDeadlineMs = requestDeadlineMs;
  }

  run(): Promise<void> {
    if (this.#running !== null) return this.#running;
    const running = this.#runOnce().finally(() => {
      if (this.#running === running) this.#running = null;
    });
    this.#running = running;
    return running;
  }

  async #runOnce(): Promise<void> {
    const jobs = await this.#store.claimProviderCleanup(new Date(), 10);
    for (const job of jobs) {
      try {
        const signal = AbortSignal.timeout(this.#requestDeadlineMs);
        if (job.action === "remove_link") {
          await this.#provider.removeLink(job.targetId, signal);
        } else if (job.action === "remove_enrollment") {
          await this.#provider.removeEnrollment(job.targetId, signal);
        } else {
          if (job.activeEnrollmentId === null) {
            throw new Error("cleanup job lost active enrollment");
          }
          await this.#provider.reconcileLink(job.targetId, job.activeEnrollmentId, signal);
        }
        await this.#store.completeProviderCleanup(job.jobId, job.claimToken);
      } catch {
        const delaySeconds = Math.min(300, 2 ** Math.min(job.attempt, 8));
        await this.#store.retryProviderCleanup(
          job.jobId,
          job.claimToken,
          new Date(Date.now() + delaySeconds * 1_000),
        );
      }
    }
  }
}
