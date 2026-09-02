import { describe, expect, test } from "bun:test";

import type { EndpointProvider } from "../../src/endpoint_provider.ts";
import { ProviderCleanupRunner } from "../../src/provider_cleanup.ts";
import type { ControlPlaneStore } from "../../src/store.ts";
import type { ProviderCleanupJob } from "../../src/types.ts";

describe("provider cleanup runner", () => {
  test("coalesces overlapping polls into one claimed batch", async () => {
    const job: ProviderCleanupJob = {
      jobId: "pcj_11111111111111111111111111111111",
      claimToken: "clm_22222222222222222222222222222222",
      linkId: "lnk_33333333333333333333333333333333",
      action: "remove_link",
      targetId: "lnk_33333333333333333333333333333333",
      activeEnrollmentId: null,
      attempt: 1,
    };
    let claimCalls = 0;
    let removeCalls = 0;
    const entered = Promise.withResolvers<void>();
    const release = Promise.withResolvers<void>();
    const store = {
      async claimProviderCleanup() {
        claimCalls += 1;
        return [job];
      },
      async completeProviderCleanup(jobId: string, claimToken: string) {
        expect({ jobId, claimToken }).toEqual({ jobId: job.jobId, claimToken: job.claimToken });
        return true;
      },
      async retryProviderCleanup() {
        throw new Error("successful cleanup must not be retried");
      },
    } satisfies Pick<
      ControlPlaneStore,
      "claimProviderCleanup" | "completeProviderCleanup" | "retryProviderCleanup"
    >;
    const provider = {
      async removeLink() {
        removeCalls += 1;
        entered.resolve();
        await release.promise;
      },
      async removeEnrollment() {
        throw new Error("unexpected removeEnrollment");
      },
      async reconcileLink() {
        throw new Error("unexpected reconcileLink");
      },
    } satisfies Pick<EndpointProvider, "removeLink" | "removeEnrollment" | "reconcileLink">;
    const runner = new ProviderCleanupRunner(store, provider, 1_000);

    const first = runner.run();
    await entered.promise;
    const overlapping = runner.run();
    expect(overlapping).toBe(first);
    expect(claimCalls).toBe(1);
    release.resolve();
    await Promise.all([first, overlapping]);
    expect(removeCalls).toBe(1);
  });
});
