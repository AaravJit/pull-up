import { assertEquals, assertNotEquals } from "jsr:@std/assert@1";
import { classify, PROVIDER_TOKEN_LIFETIME_SECONDS, ProviderTokens, responseReason } from "./apns.ts";

Deno.test("a delivered push counts as sent", () => {
  assertEquals(classify(200, undefined), "sent");
});

Deno.test("tokens Apple says will never work are dropped", () => {
  assertEquals(classify(410, "Unregistered"), "drop-token");
  assertEquals(classify(400, "BadDeviceToken"), "drop-token");
  assertEquals(classify(400, "DeviceTokenNotForTopic"), "drop-token");
});

Deno.test("our own mistakes and Apple's outages keep the token", () => {
  assertEquals(classify(400, "BadCollapseId"), "failed");
  assertEquals(classify(400, undefined), "failed");
  assertEquals(classify(403, "ExpiredProviderToken"), "failed");
  assertEquals(classify(429, "TooManyProviderTokenUpdates"), "failed");
  assertEquals(classify(500, "InternalServerError"), "failed");
  assertEquals(classify(503, "ServiceUnavailable"), "failed");
});

Deno.test("the reason is read from Apple's error body", async () => {
  assertEquals(await responseReason(Response.json({ reason: "BadDeviceToken" }, { status: 400 })), "BadDeviceToken");
  assertEquals(await responseReason(new Response("not json", { status: 500 })), undefined);
  assertEquals(await responseReason(new Response(null, { status: 200 })), undefined);
});

function counting() {
  let signed = 0;
  const tokens = new ProviderTokens((keyId, teamId, _pem, issuedAt) => {
    signed++;
    return Promise.resolve(`${teamId}.${keyId}.${issuedAt}`);
  });
  return { tokens, signed: () => signed };
}

Deno.test("the provider token is reused instead of re-signed for every push", async () => {
  const { tokens, signed } = counting();
  const first = await tokens.token("K", "T", "pem", 1_000);
  assertEquals(await tokens.token("K", "T", "pem", 1_000 + 60), first);
  assertEquals(await tokens.token("K", "T", "pem", 1_000 + PROVIDER_TOKEN_LIFETIME_SECONDS - 1), first);
  assertEquals(signed(), 1);
});

Deno.test("the provider token is replaced before Apple's one-hour limit", async () => {
  const { tokens, signed } = counting();
  const first = await tokens.token("K", "T", "pem", 1_000);
  assertNotEquals(await tokens.token("K", "T", "pem", 1_000 + PROVIDER_TOKEN_LIFETIME_SECONDS), first);
  assertEquals(signed(), 2);
  // Apple allows a new token every 20 minutes, so the lifetime must be longer.
  assertEquals(PROVIDER_TOKEN_LIFETIME_SECONDS > 20 * 60 && PROVIDER_TOKEN_LIFETIME_SECONDS < 60 * 60, true);
});

Deno.test("a new key, a rejected token or a clock going backwards signs again", async () => {
  const { tokens, signed } = counting();
  await tokens.token("K", "T", "pem", 1_000);
  await tokens.token("K2", "T", "pem", 1_010);
  assertEquals(signed(), 2);
  tokens.forget();
  await tokens.token("K2", "T", "pem", 1_020);
  assertEquals(signed(), 3);
  await tokens.token("K2", "T", "pem", 900);
  assertEquals(signed(), 4);
});
