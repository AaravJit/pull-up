// Deletes the calling user's account and everything they own
// (App Store Review Guideline 5.1.1(v)). The steps, their order and what
// happens on failure are in _shared/delete_account.ts; this file only
// connects them to Supabase.
//
// Requires SUPABASE_SERVICE_ROLE_KEY (set automatically for deployed
// functions). Sign in with Apple revocation needs the APPLE_* secrets (see
// _shared/apple.ts); without them the account is still deleted and the
// response says `apple_revoked: false, apple_reason: "not_configured"`, so
// the app can tell the person how to remove Pull Up from their Apple Account.
//
// Called with the header `x-pullup-cron-secret: <CRON_SECRET>` instead of a
// person's session, it finishes deletions that started but stopped (a
// Storage outage, the app closed mid-way). Schedule that every hour, like
// dm-retention (docs/SUPABASE_SETUP.md §5).
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { appleConfig } from "../_shared/apple.ts";
import { deleteAccount, type DeletionJobs, finishPendingDeletions } from "../_shared/delete_account.ts";

const PAGE = 1000; // PostgREST's max_rows

function sameSecret(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a);
  const y = new TextEncoder().encode(b);
  if (x.length !== y.length) return false;
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i];
  return diff === 0;
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }
  const url = Deno.env.get("SUPABASE_URL")!;
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const admin = createClient(url, serviceKey, { auth: { persistSession: false } });

  const jobs: DeletionJobs = {
    begin: async (uid) => {
      const { data, error } = await admin.rpc("account_deletion_begin", { p_user: uid });
      if (error) return { apple: null, error: error.message };
      const row = (data ?? [])[0] as { apple_token: string | null; apple_token_hint: string | null } | undefined;
      return {
        apple: row?.apple_token
          ? { token: row.apple_token, hint: row.apple_token_hint === "access_token" ? "access_token" : "refresh_token", subject: null }
          : null,
        error: null,
      };
    },
    failed: async (uid, message, apple) => {
      await admin.rpc("account_deletion_failed", {
        p_user: uid, p_error: message, p_apple_token: apple?.token ?? null, p_apple_token_hint: apple?.hint ?? null,
      });
    },
    due: async (limit) => {
      const { data, error } = await admin.rpc("account_deletions_due", { p_limit: limit });
      return { ids: ((data ?? []) as { user_id: string }[]).map((row) => row.user_id), error: error?.message ?? null };
    },
  };
  const common = {
    jobs,
    conversationIds: async (uid: string) => {
      const ids: string[] = [];
      for (let from = 0;; from += PAGE) {
        const { data, error } = await admin.from("conversations").select("id")
          .or(`user_a.eq.${uid},user_b.eq.${uid}`).order("id").range(from, from + PAGE - 1);
        if (error) return { ids, error: error.message };
        ids.push(...(data ?? []).map((row) => row.id as string));
        if ((data ?? []).length < PAGE) return { ids, error: null };
      }
    },
    storage: admin.storage,
    deleteUser: async (uid: string) => {
      const { error } = await admin.auth.admin.deleteUser(uid);
      return { error: error ? { message: error.message, status: error.status } : null };
    },
    apple: appleConfig(),
  };

  const cronHeader = req.headers.get("x-pullup-cron-secret");
  if (cronHeader !== null) {
    const secret = Deno.env.get("CRON_SECRET");
    if (!secret) return Response.json({ error: "CRON_SECRET is not configured" }, { status: 503 });
    if (!sameSecret(cronHeader, secret)) return Response.json({ error: "forbidden" }, { status: 403 });
    const result = await finishPendingDeletions(common);
    return Response.json(result.body, { status: result.status });
  }

  const authorization = req.headers.get("Authorization");
  if (!authorization) {
    return Response.json({ error: "missing authorization" }, { status: 401 });
  }
  // The caller comes from their own JWT; never trust a user id in the body.
  const asUser = createClient(url, anonKey, { global: { headers: { Authorization: authorization } } });
  const body = await req.json().catch(() => ({}));

  const result = await deleteAccount(body, {
    ...common,
    user: async () => {
      const { data, error } = await asUser.auth.getUser();
      return { user: data.user, error: error ? { message: error.message, code: error.code, status: error.status } : null };
    },
  });
  return Response.json(result.body, { status: result.status });
});
