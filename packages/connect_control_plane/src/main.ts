import { OidcAuthenticator, TestAuthenticator } from "./auth.ts";
import { createConnectApp } from "./app.ts";
import { loadConfig } from "./config.ts";
import { ExternalEndpointProvider, NoopTestEndpointProvider } from "./endpoint_provider.ts";
import { PostgresStore } from "./postgres_store.ts";
import { ProviderCleanupRunner } from "./provider_cleanup.ts";
import { ConnectService } from "./service.ts";
import { GrantSigner } from "./signer.ts";

const config = await loadConfig();
const store = new PostgresStore(config.databaseUrl, config.requestDeadlineMs);
await store.prune(new Date());
const signer = await GrantSigner.create(config.signerPrivateJwk, config.signerPreviousJwks);
const authenticator =
  config.auth.mode === "oidc"
    ? await OidcAuthenticator.create(config.auth, config.environment)
    : new TestAuthenticator(config.auth);
const endpointProvider =
  config.endpointAdapter === "external"
    ? new ExternalEndpointProvider()
    : new NoopTestEndpointProvider();
const service = new ConnectService(config, store, signer, endpointProvider);
const app = createConnectApp(config, authenticator, service, store);
const cleanupRunner = new ProviderCleanupRunner(store, endpointProvider, config.requestDeadlineMs);

const server = Bun.serve({
  hostname: config.listenHost,
  port: config.port,
  maxRequestBodySize: 64 * 1024,
  idleTimeout: 10,
  fetch(request, bunServer) {
    const clientKey = bunServer.requestIP(request)?.address ?? "unknown";
    return app.fetch(request, clientKey);
  },
});

console.log(`Verde Connect reference control plane listening on ${server.hostname}:${server.port}`);

const pruneTimer = setInterval(
  () => void store.prune(new Date()).catch(() => undefined),
  60 * 60 * 1_000,
);
pruneTimer.unref();

void cleanupRunner.run().catch(() => undefined);
const cleanupTimer = setInterval(() => void cleanupRunner.run().catch(() => undefined), 5_000);
cleanupTimer.unref();

let stopping = false;
async function stop(): Promise<void> {
  if (stopping) return;
  stopping = true;
  clearInterval(pruneTimer);
  clearInterval(cleanupTimer);
  server.stop(false);
  await store.close();
  process.exit(0);
}
process.on("SIGINT", () => void stop());
process.on("SIGTERM", () => void stop());
