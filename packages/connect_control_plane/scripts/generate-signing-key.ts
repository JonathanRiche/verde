import { calculateJwkThumbprint, exportJWK, generateKeyPair } from "jose";

const { privateKey, publicKey } = await generateKeyPair("EdDSA", {
  crv: "Ed25519",
  extractable: true,
});
const privateJwk = await exportJWK(privateKey);
const publicJwk = await exportJWK(publicKey);
const kid = await calculateJwkThumbprint(publicJwk, "sha256");

process.stdout.write(
  `${JSON.stringify({ ...privateJwk, kid, use: "sig", alg: "EdDSA" }, null, 2)}\n`,
);
