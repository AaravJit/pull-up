// App Store Server Notifications V2 endpoint. Set its URL as the Production
// and Sandbox Server URL in App Store Connect (docs/RELEASE_CHECKLIST.md).
// Deployed with verify_jwt = false (supabase/config.toml) because Apple
// doesn't send a Supabase token.
//
// The notification body is only a hint: it says which subscription changed.
// What is stored comes from the App Store Server API, so a forged
// notification can at most make us re-read the truth from Apple. Notifications
// are recorded by notificationUUID so Apple's retries are no-ops.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { applyArguments, AppStoreError, fetchSubscription, loadConfig, readJwsPayload, type TransactionInfo } from "../_shared/appstore.ts";

interface NotificationPayload {
  notificationType?: string;
  subtype?: string;
  notificationUUID?: string;
  signedDate?: number;
  data?: { bundleId?: string; environment?: string; signedTransactionInfo?: string };
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });
  const config = loadConfig();
  // 503 makes Apple retry later, once the secrets are set.
  if (!config) return Response.json({ error: "not_configured" }, { status: 503 });

  const body = await req.json().catch(() => ({})) as { signedPayload?: unknown };
  if (typeof body.signedPayload !== "string" || body.signedPayload.length > 64_000) {
    return Response.json({ error: "malformed" }, { status: 400 });
  }
  let payload: NotificationPayload;
  try {
    payload = readJwsPayload<NotificationPayload>(body.signedPayload);
  } catch {
    return Response.json({ error: "malformed" }, { status: 400 });
  }
  const age = Date.now() - (payload.signedDate ?? 0);
  if (!payload.notificationUUID || !UUID.test(payload.notificationUUID) || payload.data?.bundleId !== config.bundleId ||
      age < -300_000 || age > 30 * 86_400_000) {
    return Response.json({ error: "malformed" }, { status: 400 });
  }
  if (payload.notificationType === "TEST") return Response.json({ ok: true, test: true });

  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false },
  });
  const { data: seen } = await admin.from("app_store_notifications").select("notification_uuid")
    .eq("notification_uuid", payload.notificationUUID).maybeSingle();
  if (seen) return Response.json({ ok: true, duplicate: true });

  let transaction: TransactionInfo = {};
  try {
    if (payload.data?.signedTransactionInfo) transaction = readJwsPayload<TransactionInfo>(payload.data.signedTransactionInfo);
  } catch {
    return Response.json({ error: "malformed" }, { status: 400 });
  }
  const record = async () => {
    await admin.from("app_store_notifications").upsert({
      notification_uuid: payload.notificationUUID,
      notification_type: payload.notificationType ?? "UNKNOWN",
      subtype: payload.subtype ?? null,
      original_transaction_id: transaction.originalTransactionId ?? null,
      environment: payload.data?.environment ?? null,
    }, { onConflict: "notification_uuid", ignoreDuplicates: true });
  };
  if (!transaction.transactionId) {
    await record();
    return Response.json({ ok: true, ignored: "no transaction" });
  }

  let subscription;
  try {
    subscription = await fetchSubscription(config, transaction.transactionId, fetch, transaction.originalTransactionId);
  } catch (error) {
    if (error instanceof AppStoreError && ["not_found", "malformed", "unknown_product", "wrong_app"].includes(error.code)) {
      return Response.json({ ok: true, ignored: error.code });
    }
    return Response.json({ error: "apple_unavailable" }, { status: 502 });
  }
  // Bought outside the app (no account attached): nothing to update until
  // the person opens Pull Up and their purchase is checked there.
  if (!subscription.appAccountToken || !UUID.test(subscription.appAccountToken)) {
    await record();
    return Response.json({ ok: true, ignored: "no account" });
  }
  const { error: applyError } = await admin.rpc("apply_entitlement", applyArguments(subscription.appAccountToken, subscription));
  // 23503: the account was deleted. 23505: recorded on another account.
  if (applyError && applyError.code !== "23503" && applyError.code !== "23505") {
    return Response.json({ error: applyError.message }, { status: 500 });
  }
  await record();
  return Response.json({ ok: true });
});
