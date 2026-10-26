// Deletes post-media files that no post refers to, a day after upload
// (public.post_orphaned_media, migration 20261025000200): uploads for posts
// that never published (the upload failed or was cancelled, the app was
// closed mid-upload, the draft was abandoned) and the files of deleted
// posts. Files a report refers to are kept.
//
// Schedule it like dm-retention: Supabase Cron (Integrations ▸ Cron) or any
// scheduler, calling this function daily with the header
// `x-pullup-cron-secret: <CRON_SECRET>`. See docs/SUPABASE_SETUP.md §5.
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
  let removed = 0;
  // Each pass lists at most 1,000; stop after 20 so one run stays bounded.
  for (let pass = 0; pass < 20; pass++) {
    const { data: rows, error: listError } = await admin.rpc("post_orphaned_media", { p_limit: 1000 });
    if (listError) return Response.json({ error: listError.message, removed }, { status: 500 });
    const names = ((rows ?? []) as { name: string }[]).map((row) => row.name);
    for (let i = 0; i < names.length; i += 100) {
      const { error: removeError } = await admin.storage.from("post-media").remove(names.slice(i, i + 100));
      if (removeError) return Response.json({ error: removeError.message, removed }, { status: 500 });
      removed += Math.min(100, names.length - i);
    }
    if (names.length < 1000) break;
  }
  return Response.json({ orphaned_media: removed });
});
