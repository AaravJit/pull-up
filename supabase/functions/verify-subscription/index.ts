// Records the caller's Pull Up Pro subscription after a purchase, a restore
// or at launch. The app sends the StoreKit transaction it holds; the state
// that is stored comes from Apple's App Store Server API (see
// _shared/appstore.ts), and only if Apple confirms the purchase was made
// for this Pull Up account (appAccountToken = the caller's user id).
//
// Answers with the caller's entitlement, the same shape as
// public.my_entitlement(), or { error } with one of:
//   not_configured (503)     App Store secrets are not set.
//   xcode_environment (422)  A local StoreKit-testing transaction; Apple
//                            can't confirm it, so it grants nothing.
//   other_account (403/409)  The subscription was bought for, or is already
//                            recorded on, a different Pull Up account.
//   rate_limited (429)       More than 10 calls in a minute or 60 in an
//                            hour from this account.
//   not_found (404), malformed (400), apple_unavailable (502).
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { applyArguments, AppStoreError, fetchSubscription, loadConfig, readJwsPayload, type TransactionInfo } from "../_shared/appstore.ts";

const fail = (error: string, status: number) => Response.json({ error }, { status });

// The app calls this at launch and after a purchase or restore, so these
// leave plenty of room while keeping one account from hammering Apple.
const PER_MINUTE = 10;
const PER_HOUR = 60;

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });
  const authorization = req.headers.get("Authorization");
  if (!authorization) return fail("missing authorization", 401);

  const url = Deno.env.get("SUPABASE_URL")!;
  const asUser = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: authorization } } });
  const { data: userData, error: userError } = await asUser.auth.getUser();
  if (userError || !userData.user) return fail("invalid session", 401);
  const uid = userData.user.id.toLowerCase();

  const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const { data: allowed, error: limitError } = await admin.rpc("take_function_slot", {
    p_user: uid, p_function: "verify-subscription", p_per_minute: PER_MINUTE, p_per_hour: PER_HOUR,
  });
  if (limitError) return fail(limitError.message, 500);
  if (allowed !== true) return fail("rate_limited", 429);

  const body = await req.json().catch(() => ({})) as { signed_transaction?: unknown };
  if (typeof body.signed_transaction !== "string" || body.signed_transaction.length > 16_000) return fail("malformed", 400);

  let claimed: TransactionInfo;
  try {
    claimed = readJwsPayload<TransactionInfo>(body.signed_transaction);
  } catch {
    return fail("malformed", 400);
  }
  if (claimed.environment === "Xcode") return fail("xcode_environment", 422);
  const config = loadConfig();
  if (!config) return fail("not_configured", 503);
  if (claimed.bundleId !== config.bundleId || !claimed.transactionId) return fail("malformed", 400);

  let subscription;
  try {
    subscription = await fetchSubscription(config, claimed.transactionId, fetch, claimed.originalTransactionId);
  } catch (error) {
    if (error instanceof AppStoreError) {
      switch (error.code) {
        case "not_found": return fail("not_found", 404);
        case "malformed": case "unknown_product": case "wrong_app": return fail("malformed", 400);
        default: return fail("apple_unavailable", 502);
      }
    }
    return fail("apple_unavailable", 502);
  }
  // Never bind a subscription to whoever presents it: Apple must say it was
  // bought from this account.
  if (subscription.appAccountToken !== uid) return fail("other_account", 403);

  const { error: applyError } = await admin.rpc("apply_entitlement", applyArguments(uid, subscription));
  if (applyError) {
    return applyError.code === "23505" ? fail("other_account", 409) : fail(applyError.message, 500);
  }
  const { data, error } = await asUser.rpc("my_entitlement").single();
  if (error) return fail(error.message, 500);
  return Response.json(data);
});
