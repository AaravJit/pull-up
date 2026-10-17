// Applies the direct-message retention rules once a day (see public.dm_purge
// in migration 20261017000200_direct_messages.sql) and deletes the photos of
// the messages it removed.
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
  return Response.json({ purged_media: paths.length });
});
