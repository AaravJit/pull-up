// Deletes the calling user's account and everything they own.
//
// App Store Review Guideline 5.1.1(v) requires in-app account deletion.
// Database rows cascade from auth.users; Storage objects do not, so they are
// removed first. Requires SUPABASE_SERVICE_ROLE_KEY (set automatically for
// deployed functions).
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

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
  return Response.json({ deleted: true });
});
