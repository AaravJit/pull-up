import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
import { alertPayload, digestPayload, type QueueSummary, signature, testPayload, webhookTarget } from "./moderation.ts";

const summary: QueueSummary = {
  open: 3, urgent_open: 1, oldest_open_at: "2026-10-25T10:00:00Z", open_over_24h: 0,
  deliveries_pending: 2, deliveries_failed: 0, media_due: 0, terms: 12, moderators: 1,
};

Deno.test("only https URLs are used as the endpoint", () => {
  assertEquals(webhookTarget(undefined), null);
  assertEquals(webhookTarget(" "), null);
  assertEquals(webhookTarget("http://hooks.example.com/x"), null);
  assertEquals(webhookTarget("not a url"), null);
  assertEquals(webhookTarget("https://localhost/x"), null);
  assertEquals(webhookTarget("https://hooks.example.com/services/x")?.hostname, "hooks.example.com");
});

Deno.test("an alert names counts and reasons, never content or people", () => {
  const payload = alertPayload([
    { report_id: "r1", reason: "violence", priority: "urgent", content_kind: "post", created_at: "2026-10-25T10:00:00Z", attempts: 0 },
    { report_id: "r2", reason: "spam", priority: "normal", content_kind: "comment", created_at: "2026-10-25T10:01:00Z", attempts: 1 },
  ], summary, "staging");
  assertEquals(payload.text, "Pull Up moderation (staging): 2 new reports, 1 urgent (violence, spam). Open queue: 3, 1 urgent. Open it with: select * from public.mod_queue();");
  assertEquals(payload.content, payload.text);
  assertEquals(Object.keys(payload.reports[0]).sort(), ["content_kind", "created_at", "id", "priority", "reason"]);
});

Deno.test("an empty term list is called out", () => {
  const payload = alertPayload([
    { report_id: "r1", reason: "hate", priority: "normal", content_kind: null, created_at: "2026-10-25T10:00:00Z", attempts: 0 },
  ], { ...summary, terms: 0 }, "");
  assertStringIncludes(payload.text, "1 new report (hate)");
  assertStringIncludes(payload.text, "text filter has no terms");
});

Deno.test("the digest stays quiet when nothing needs attention", () => {
  assertEquals(digestPayload({ ...summary, open: 0, urgent_open: 0, oldest_open_at: null }, "production"), null);
  const digest = digestPayload({ ...summary, open_over_24h: 2, deliveries_failed: 1 }, "production");
  assert(digest);
  assertStringIncludes(digest.text, "2 older than 24 h");
  assertStringIncludes(digest.text, "1 alert failed to deliver");
});

Deno.test("the signature is HMAC-SHA256 of the body", async () => {
  // RFC 4231 test case 2.
  assertEquals(await signature("Jefe", "what do ya want for nothing?"),
    "sha256=5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843");
});

Deno.test("the test alert says what it is and carries nothing else", () => {
  const p = testPayload("production");
  assertEquals(p.kind, "pullup.moderation.test");
  assertEquals(p.text, p.content);
  assertStringIncludes(p.text, "(production): test alert");
  assertStringIncludes(p.text, "No report was filed");
  assertEquals(Object.keys(p).sort(), ["content", "kind", "text"]);
});
