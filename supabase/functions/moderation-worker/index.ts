// Delivers new reports to the owner and carries out moderation housekeeping.
// Run it every 5 minutes with Supabase Cron (and once a day with
// {"digest": true}), sending `x-pullup-cron-secret: <CRON_SECRET>` and the
// anon key as the bearer token, like dm-retention (docs/MODERATION_RUNBOOK.md).
//
// Each run:
//   1. deletes from Storage the photos and videos of removed content whose
//      evidence hold has ended (public.moderation_due_media), recording each
//      result;
//   2. applies the moderation retention rules (public.moderation_purge);
//   3. leases undelivered reports (public.moderation_claim_deliveries) and
//      POSTs one JSON message about them to MODERATION_WEBHOOK_URL, then
//      records delivered, or the error and the next retry
//      (public.moderation_record_delivery: backoff 2 min .. 6 h, gives up
//      after 12 attempts and the report shows "failed" in the queue);
//   4. with {"digest": true}: sends a summary of the open queue, if anything
//      is open or failed.
//
// Secrets: CRON_SECRET (required), MODERATION_WEBHOOK_URL (an https URL the
// owner chooses: a Slack or Discord incoming webhook, an ntfy topic, or an
// endpoint of their own; all free). Optional MODERATION_WEBHOOK_SECRET signs
// the body (x-pullup-signature: sha256=<hex HMAC>), and
// PULLUP_ENVIRONMENT_NAME labels messages ("staging"). Without
// MODERATION_WEBHOOK_URL reports keep queueing, nothing is sent, and the
// function answers 503 so the cron history shows it isn't configured.
// The message carries no reported content or names (see _shared/moderation.ts).
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import {
  alertPayload,
  digestPayload,
  type PendingReport,
  type QueueSummary,
  signature,
  webhookTarget,
} from "../_shared/moderation.ts";

function sameSecret(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a);
  const y = new TextEncoder().encode(b);
  if (x.length !== y.length) return false;
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i];
  return diff === 0;
}

async function post(url: URL, payload: unknown): Promise<string | null> {
  const body = JSON.stringify(payload);
  const headers: Record<string, string> = { "Content-Type": "application/json" };
  const secret = Deno.env.get("MODERATION_WEBHOOK_SECRET");
  if (secret) headers["x-pullup-signature"] = await signature(secret, body);
  try {
    const res = await fetch(url, { method: "POST", headers, body, signal: AbortSignal.timeout(10_000) });
    await res.body?.cancel();
    return res.ok ? null : `HTTP ${res.status}`;
  } catch (error) {
    return error instanceof Error ? error.name + ": " + error.message : String(error);
  }
}

Deno.serve(async (req: Request): Promise<Response> => {
  const cronSecret = Deno.env.get("CRON_SECRET");
  if (!cronSecret) return Response.json({ error: "CRON_SECRET is not configured" }, { status: 503 });
  if (!sameSecret(req.headers.get("x-pullup-cron-secret") ?? "", cronSecret)) {
    return Response.json({ error: "forbidden" }, { status: 403 });
  }
  const { digest } = await req.json().catch(() => ({})) as { digest?: boolean };
  const environment = Deno.env.get("PULLUP_ENVIRONMENT_NAME") ?? "";
  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false },
  });

  // 1. Media of removed content, once its evidence hold has ended.
  let mediaRemoved = 0;
  const mediaErrors: string[] = [];
  const { data: due, error: dueError } = await admin.rpc("moderation_due_media", { p_limit: 500 });
  if (dueError) return Response.json({ error: `moderation_due_media: ${dueError.message}` }, { status: 500 });
  const byBucket = new Map<string, string[]>();
  for (const row of (due ?? []) as { bucket: string; path: string }[]) {
    byBucket.set(row.bucket, [...(byBucket.get(row.bucket) ?? []), row.path]);
  }
  for (const [bucket, paths] of byBucket) {
    for (let i = 0; i < paths.length; i += 100) {
      const chunk = paths.slice(i, i + 100);
      const { error } = await admin.storage.from(bucket).remove(chunk);
      const problem = error ? error.message.slice(0, 300) : null;
      await admin.rpc("moderation_media_removed", { p_bucket: bucket, p_paths: chunk, p_error: problem });
      if (problem) mediaErrors.push(`${bucket}: ${problem}`);
      else mediaRemoved += chunk.length;
    }
  }

  // 2. Retention.
  const { error: purgeError } = await admin.rpc("moderation_purge");
  if (purgeError) return Response.json({ error: `moderation_purge: ${purgeError.message}` }, { status: 500 });

  const { data: summaryData, error: summaryError } = await admin.rpc("moderation_summary");
  if (summaryError) return Response.json({ error: `moderation_summary: ${summaryError.message}` }, { status: 500 });
  const summary = summaryData as QueueSummary;

  // 3. Deliveries.
  const url = webhookTarget(Deno.env.get("MODERATION_WEBHOOK_URL"));
  if (!url) {
    return Response.json({
      error: "MODERATION_WEBHOOK_URL is not configured (or isn't an https URL); reports are queued but nobody is told",
      undelivered: summary.deliveries_pending,
      media_removed: mediaRemoved,
    }, { status: 503 });
  }
  let delivered = 0;
  let failed = 0;
  for (let batch = 0; batch < 5; batch++) {
    const { data: claimed, error: claimError } = await admin.rpc("moderation_claim_deliveries", { p_limit: 20 });
    if (claimError) return Response.json({ error: `moderation_claim_deliveries: ${claimError.message}` }, { status: 500 });
    const reports = (claimed ?? []) as PendingReport[];
    if (reports.length === 0) break;
    const problem = await post(url, alertPayload(reports, summary, environment));
    const { error: recordError } = await admin.rpc("moderation_record_delivery", {
      p_reports: reports.map((r) => r.report_id),
      p_ok: problem === null,
      p_error: problem,
    });
    if (recordError) return Response.json({ error: `moderation_record_delivery: ${recordError.message}` }, { status: 500 });
    if (problem) {
      failed += reports.length;
      break;
    }
    delivered += reports.length;
  }

  // 4. Daily digest.
  let digestSent: boolean | null = null;
  if (digest) {
    const payload = digestPayload(summary, environment);
    digestSent = payload ? (await post(url, payload)) === null : false;
  }

  const status = failed > 0 || mediaErrors.length > 0 ? 502 : 200;
  return Response.json({ delivered, failed, media_removed: mediaRemoved, media_errors: mediaErrors, digest_sent: digestSent }, { status });
});
