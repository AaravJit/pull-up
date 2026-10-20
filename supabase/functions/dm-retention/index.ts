// Applies the direct-message retention rules once a day (see public.dm_purge
// in migration 20261017000200_direct_messages.sql) and deletes the photos of
// the messages it removed. Then deletes DM photos no message refers to any
// more, a day after upload: sends that failed or were abandoned, and unsent
// messages (public.dm_orphaned_media, migration 20261018000800).
//
// Schedule it with Supabase Cron (Integrations ▸ Cron) or any scheduler,
// calling this function daily with the header
// `x-pullup-cron-secret: <CRON_SECRET>`. See docs/RELEASE_CHECKLIST.md.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

function sameSecret(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a);
  const y = new TextEncoder().encode(b);
  if (x.length !== y.length) return false;
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i];
  return diff === 0;
}

Deno.serve(async (req: Request): Promise<Response> => {
  const secret = Deno.env.get("CRON_SECRET");
  if (!secret) return Response.json({ error: "CRON_SECRET is not configured" }, { status: 503 });
  if (!sameSecret(req.headers.get("x-pullup-cron-secret") ?? "", secret)) {
    return Response.json({ error: "forbidden" }, { status: 403 });
  }
  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false },
  });
  const { data, error } = await admin.rpc("dm_purge");
  if (error) return Response.json({ error: error.message }, { status: 500 });
  const paths = ((data ?? []) as { media_path: string }[]).map((row) => row.media_path);
  for (let i = 0; i < paths.length; i += 100) {
    const { error: removeError } = await admin.storage.from("dm-media").remove(paths.slice(i, i + 100));
    if (removeError) return Response.json({ error: removeError.message, removed: i }, { status: 500 });
  }
  let orphans = 0;
  // Each pass lists at most 1,000; stop after 20 so one run stays bounded.
  for (let pass = 0; pass < 20; pass++) {
    const { data: rows, error: listError } = await admin.rpc("dm_orphaned_media", { p_limit: 1000 });
    if (listError) return Response.json({ error: listError.message, purged_media: paths.length }, { status: 500 });
    const names = ((rows ?? []) as { name: string }[]).map((row) => row.name);
    for (let i = 0; i < names.length; i += 100) {
      const { error: removeError } = await admin.storage.from("dm-media").remove(names.slice(i, i + 100));
      if (removeError) return Response.json({ error: removeError.message, purged_media: paths.length, orphans }, { status: 500 });
      orphans += Math.min(100, names.length - i);
    }
    if (names.length < 1000) break;
  }
  return Response.json({ purged_media: paths.length, orphaned_media: orphans });
});
