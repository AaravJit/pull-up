// Deletes the calling user's account and everything they own.
//
// App Store Review Guideline 5.1.1(v) requires in-app account deletion, and
// for Sign in with Apple accounts, revoking Apple's tokens. Database rows
// cascade from auth.users; Storage objects do not, so they are removed first.
// Requires SUPABASE_SERVICE_ROLE_KEY (set automatically for deployed
// functions). Apple revocation needs the APPLE_* secrets (see _shared/apple.ts);
// without them the account is still deleted and the response says
// `apple_revoked: false` with the reason, so the app can tell the person how
// to remove Pull Up from their Apple ID by hand.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { type RevocationResult, revokeAppleTokens } from "../_shared/apple.ts";

const BUCKETS = ["avatars", "vehicle-media", "post-media"];

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

  // Resolve the caller from their own JWT; never trust a user id in the body.
  const asUser = createClient(url, anonKey, { global: { headers: { Authorization: authorization } } });
  const { data: userData, error: userError } = await asUser.auth.getUser();
  if (userError || !userData.user) {
    return Response.json({ error: "invalid session" }, { status: 401 });
  }
  const uid = userData.user.id;
  const admin = createClient(url, serviceKey, { auth: { persistSession: false } });

  const body = await req.json().catch(() => ({})) as { apple_authorization_code?: unknown };
  const usesApple = (userData.user.identities ?? []).some((identity) => identity.provider === "apple");
  let apple: RevocationResult | null = null;
  if (usesApple) {
    const code = typeof body.apple_authorization_code === "string" ? body.apple_authorization_code : undefined;
    // Best effort: a failure here must not leave the person unable to delete.
    apple = await revokeAppleTokens(code).catch(() => ({ revoked: false, reason: "revoke_failed" } as const));
  }

  // Message photos live under "<conversation>/<sender>/...". The person's
  // conversations are deleted with the account, so their whole folders go,
  // including what the other person sent in them.
  const { data: conversations, error: conversationError } = await admin.from("conversations")
    .select("id").or(`user_a.eq.${uid},user_b.eq.${uid}`);
  if (conversationError) return Response.json({ error: conversationError.message }, { status: 500 });
  const removeTree = async (bucket: string, root: string): Promise<string | null> => {
    const queue = [root];
    while (queue.length > 0) {
      const prefix = queue.pop()!;
      const { data: entries, error } = await admin.storage.from(bucket).list(prefix, { limit: 1000 });
      if (error) return `listing ${bucket}: ${error.message}`;
      const files: string[] = [];
      for (const entry of entries ?? []) {
        if (entry.id === null) queue.push(`${prefix}/${entry.name}`);
        else files.push(`${prefix}/${entry.name}`);
      }
      if (files.length > 0) {
        const { error: removeError } = await admin.storage.from(bucket).remove(files);
        if (removeError) return `removing from ${bucket}: ${removeError.message}`;
      }
    }
    return null;
  };
  for (const conversation of conversations ?? []) {
    const problem = await removeTree("dm-media", conversation.id);
    if (problem) return Response.json({ error: problem }, { status: 500 });
  }

  for (const bucket of BUCKETS) {
    // Objects live under "<uid>/..."; list recursively one level at a time.
    const queue = [uid];
    while (queue.length > 0) {
      const prefix = queue.pop()!;
      const { data: entries, error } = await admin.storage.from(bucket).list(prefix, { limit: 1000 });
      if (error) return Response.json({ error: `listing ${bucket}: ${error.message}` }, { status: 500 });
      const files: string[] = [];
      for (const entry of entries ?? []) {
        if (entry.id === null) queue.push(`${prefix}/${entry.name}`);
        else files.push(`${prefix}/${entry.name}`);
      }
      if (files.length > 0) {
        const { error: removeError } = await admin.storage.from(bucket).remove(files);
        if (removeError) return Response.json({ error: `removing from ${bucket}: ${removeError.message}` }, { status: 500 });
      }
    }
  }

  const { error: deleteError } = await admin.auth.admin.deleteUser(uid);
  if (deleteError) {
    return Response.json({ error: deleteError.message }, { status: 500 });
  }
  return Response.json({
    deleted: true,
    apple_revoked: apple ? apple.revoked : null,
    apple_reason: apple && !apple.revoked ? apple.reason : null,
  });
});
