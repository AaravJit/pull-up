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
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { appleConfig } from "../_shared/apple.ts";
import { deleteAccount } from "../_shared/delete_account.ts";

const PAGE = 1000; // PostgREST's max_rows

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }
  const authorization = req.headers.get("Authorization");
  if (!authorization) {
    return Response.json({ error: "missing authorization" }, { status: 401 });
  }

  const url = Deno.env.get("SUPABASE_URL")!;
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  // The caller comes from their own JWT; never trust a user id in the body.
  const asUser = createClient(url, anonKey, { global: { headers: { Authorization: authorization } } });
  const admin = createClient(url, serviceKey, { auth: { persistSession: false } });
  const body = await req.json().catch(() => ({}));

  const result = await deleteAccount(body, {
    user: async () => {
      const { data, error } = await asUser.auth.getUser();
      return { user: data.user, error: error ? { message: error.message, code: error.code, status: error.status } : null };
    },
    conversationIds: async (uid) => {
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
    deleteUser: async (uid) => {
      const { error } = await admin.auth.admin.deleteUser(uid);
      return { error };
    },
    apple: appleConfig(),
  });
  return Response.json(result.body, { status: result.status });
});
