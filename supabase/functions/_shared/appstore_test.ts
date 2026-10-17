// deno test supabase/functions/_shared/
// Exercises the App Store Server API client against a stubbed Apple, with a
// throwaway key generated per run. No network, no real credentials.
import { type AppStoreConfig, apiToken, AppStoreError, applyArguments, fetchSubscription, loadConfig, readJwsPayload } from "./appstore.ts";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}
function assertEquals<T>(actual: T, expected: T, message = "") {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`${message} expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

const b64url = (bytes: Uint8Array) => btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const fakeJws = (payload: unknown) => `e30.${b64url(new TextEncoder().encode(JSON.stringify(payload)))}.c2ln`;

const keys = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", keys.privateKey));
const pem = `-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...pkcs8))}\n-----END PRIVATE KEY-----`;
const config: AppStoreConfig = { issuerId: "issuer", keyId: "KEY123", privateKey: pem, bundleId: "app.pullup.ios" };
const account = "0b6f3e3e-9c1d-4b6a-8f6e-2a1d3c4b5e6f";

function apple(status: number, items: unknown[], options: { bundleId?: string; sandboxOnly?: boolean } = {}) {
  const calls: string[] = [];
  const impl = (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const url = String(input);
    calls.push(url);
    assert(new Headers(init?.headers).get("authorization")?.startsWith("Bearer "), "sends a bearer token");
    if (options.sandboxOnly && url.includes("api.storekit.itunes")) return Promise.resolve(new Response("{}", { status: 404 }));
    if (status !== 200) return Promise.resolve(new Response("{}", { status }));
    return Promise.resolve(Response.json({
      environment: options.sandboxOnly ? "Sandbox" : "Production",
      bundleId: options.bundleId ?? config.bundleId,
      data: [{ subscriptionGroupIdentifier: "21500001", lastTransactions: items }],
    }));
  };
  return { calls, impl: impl as typeof fetch };
}

const now = Date.now();
const item = (overrides: Record<string, unknown> = {}, renewal: Record<string, unknown> = {}, status = 1) => ({
  status,
  originalTransactionId: "2000000000000001",
  signedTransactionInfo: fakeJws({
    transactionId: "2000000000000009", originalTransactionId: "2000000000000001", bundleId: config.bundleId,
    productId: "app.pullup.pro.yearly", expiresDate: now + 86_400_000, appAccountToken: account.toUpperCase(),
    environment: "Production", signedDate: now, ...overrides,
  }),
  signedRenewalInfo: fakeJws({ autoRenewStatus: 1, signedDate: now, ...renewal }),
});

Deno.test("API token is an ES256 JWT for the app, short-lived", async () => {
  const token = await apiToken(config, now);
  const [header, claims, signature] = token.split(".");
  const h = readJwsPayload<Record<string, string>>(`x.${header}.x`);
  const c = readJwsPayload<Record<string, string | number>>(`x.${claims}.x`);
  assertEquals(h, { alg: "ES256", kid: "KEY123", typ: "JWT" });
  assertEquals(c.aud, "appstoreconnect-v1");
  assertEquals(c.bid, config.bundleId);
  assert((c.exp as number) - (c.iat as number) <= 300, "expires within 5 minutes");
  const sig = Uint8Array.from(atob(signature.replace(/-/g, "+").replace(/_/g, "/") + "==".slice(0, (4 - signature.length % 4) % 4)), (ch) => ch.charCodeAt(0));
  const ok = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, keys.publicKey, sig,
    new TextEncoder().encode(`${header}.${claims}`));
  assert(ok, "signature verifies with the key's public half");
});

Deno.test("an active subscription maps to apply_entitlement arguments", async () => {
  const stub = apple(200, [item()]);
  const sub = await fetchSubscription(config, "2000000000000009", stub.impl, "2000000000000001");
  assertEquals(sub.status, "active");
  assertEquals(sub.environment, "Production");
  assertEquals(sub.appAccountToken, account, "account token is normalised to lower case");
  assertEquals(sub.autoRenew, true);
  assertEquals(stub.calls.length, 1);
  const args = applyArguments(account, sub);
  assertEquals(args.p_product_id, "app.pullup.pro.yearly");
  assertEquals(args.p_original_transaction_id, "2000000000000001");
});

Deno.test("falls back to sandbox when production doesn't know the transaction", async () => {
  const stub = apple(200, [item({ environment: "Sandbox" })], { sandboxOnly: true });
  const sub = await fetchSubscription(config, "2000000000000009", stub.impl);
  assertEquals(sub.environment, "Sandbox");
  assertEquals(stub.calls.length, 2);
  assert(stub.calls[1].includes("sandbox"), "second call goes to sandbox");
});

Deno.test("Apple's statuses and refunds", async () => {
  const cases: [number, Record<string, unknown>, Record<string, unknown>, string][] = [
    [2, {}, { autoRenewStatus: 0 }, "expired"],
    [3, {}, {}, "billing_retry"],
    [4, {}, { gracePeriodExpiresDate: now + 3_600_000 }, "grace_period"],
    [5, {}, {}, "revoked"],
    [1, { revocationDate: now }, {}, "revoked"],
  ];
  for (const [status, tx, renewal, expected] of cases) {
    const sub = await fetchSubscription(config, "2000000000000009", apple(200, [item(tx, renewal, status)]).impl);
    assertEquals(sub.status, expected, `status ${status}`);
  }
  const grace = await fetchSubscription(config, "1", apple(200, [item({}, { gracePeriodExpiresDate: now + 1000 }, 4)]).impl);
  assertEquals(grace.graceExpiresAt, new Date(now + 1000).toISOString());
});

Deno.test("refuses other apps, other products, unknown transactions and bad ids", async () => {
  const rejects = async (promise: Promise<unknown>, code: string) => {
    try {
      await promise;
    } catch (error) {
      assert(error instanceof AppStoreError && error.code === code, `expected ${code}, got ${error}`);
      return;
    }
    throw new Error(`expected ${code}`);
  };
  await rejects(fetchSubscription(config, "1", apple(200, [item()], { bundleId: "com.other.app" }).impl), "wrong_app");
  await rejects(fetchSubscription(config, "2000000000000009", apple(200, [item({ productId: "com.other.coins" })]).impl), "unknown_product");
  await rejects(fetchSubscription(config, "1", apple(404, []).impl), "not_found");
  await rejects(fetchSubscription(config, "1", apple(401, []).impl), "unauthorized");
  await rejects(fetchSubscription(config, "1", apple(500, []).impl), "apple_unavailable");
  await rejects(fetchSubscription(config, "../../admin", apple(200, [item()]).impl), "malformed");
});

Deno.test("a purchase without an account token stays unbound", async () => {
  const sub = await fetchSubscription(config, "1", apple(200, [item({ appAccountToken: undefined })]).impl);
  assertEquals(sub.appAccountToken, null);
});

Deno.test("config needs every secret", () => {
  assertEquals(loadConfig(() => undefined), null);
  assertEquals(loadConfig((n) => (n === "APPSTORE_BUNDLE_ID" ? undefined : "x")), null);
  assert(loadConfig(() => "x") !== null, "all set");
});

Deno.test("JWS payloads that aren't JWS are rejected", () => {
  try {
    readJwsPayload("not-a-jws");
  } catch (error) {
    assert(error instanceof AppStoreError && error.code === "malformed", "malformed");
    return;
  }
  throw new Error("expected malformed");
});
