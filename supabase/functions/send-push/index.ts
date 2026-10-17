// Sends APNs pushes for new notifications rows.
//
// Wire-up (production): a Database Webhook on INSERT into public.notifications
// calls this function with the new row and an `x-pullup-webhook-secret`
// header. Requires these secrets (docs/RELEASE_CHECKLIST.md):
//   PUSH_WEBHOOK_SECRET (random, also set as the webhook's header)
//   APNS_KEY_ID, APNS_TEAM_ID, APNS_PRIVATE_KEY (contents of the .p8), APNS_TOPIC
// Without them the function returns 503 and nothing is sent; in-app
// notifications still work because they are read straight from the table.
//
// The anon key is public, so anyone can reach this URL. The shared secret
// stops strangers from triggering pushes, and only the notification id is
// taken from the request: recipient, actor and kind are re-read from the
// database, so a forged body can't push arbitrary text to arbitrary people.
// public.push_content applies the recipient's notification preferences and
// returns message text only if they turned previews on.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { type PushContent, pushAlert } from "../_shared/push.ts";

function sameSecret(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a);
  const y = new TextEncoder().encode(b);
  if (x.length !== y.length) return false;
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i];
  return diff === 0;
}

function base64UrlEncode(bytes: Uint8Array): string {
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function providerToken(keyId: string, teamId: string, pem: string): Promise<string> {
  const der = Uint8Array.from(atob(pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "")), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const enc = new TextEncoder();
  const header = base64UrlEncode(enc.encode(JSON.stringify({ alg: "ES256", kid: keyId })));
  const claims = base64UrlEncode(enc.encode(JSON.stringify({ iss: teamId, iat: Math.floor(Date.now() / 1000) })));
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, enc.encode(`${header}.${claims}`));
  return `${header}.${claims}.${base64UrlEncode(new Uint8Array(signature))}`;
}

Deno.serve(async (req: Request): Promise<Response> => {
  const webhookSecret = Deno.env.get("PUSH_WEBHOOK_SECRET");
  if (!webhookSecret) {
    return Response.json({ error: "push webhook secret is not configured" }, { status: 503 });
  }
  if (!sameSecret(req.headers.get("x-pullup-webhook-secret") ?? "", webhookSecret)) {
    return Response.json({ error: "forbidden" }, { status: 403 });
  }
  const keyId = Deno.env.get("APNS_KEY_ID");
  const teamId = Deno.env.get("APNS_TEAM_ID");
  const privateKey = Deno.env.get("APNS_PRIVATE_KEY");
  const topic = Deno.env.get("APNS_TOPIC");
  if (!keyId || !teamId || !privateKey || !topic) {
    return Response.json({ error: "APNs is not configured" }, { status: 503 });
  }

  const payload = await req.json().catch(() => ({})) as { record?: { id?: unknown } };
  const id = payload.record?.id;
  if (typeof id !== "string") return Response.json({ error: "no record" }, { status: 400 });

  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false },
  });
  const { data: rows, error } = await admin.rpc("push_content", { p_notification: id });
  if (error) return Response.json({ error: "lookup failed" }, { status: 500 });
  const row = (rows as PushContent[] | null)?.[0];
  if (!row) return Response.json({ error: "unknown notification" }, { status: 404 });
  // Each notification is pushed at most once, so replaying a request does nothing.
  if (row.already_pushed) return Response.json({ sent: 0, duplicate: true });
  const markPushed = () => admin.from("notifications").update({ pushed_at: new Date().toISOString() }).eq("id", id);
  if (!row.allowed) {
    await markPushed();
    return Response.json({ sent: 0, off: true });
  }
  const { data: tokens } = await admin.from("device_tokens").select("token, environment")
    .eq("user_id", row.recipient_id).eq("platform", "ios");
  if (!tokens || tokens.length === 0) return Response.json({ sent: 0 });

  const alert = pushAlert(row);
  const jwt = await providerToken(keyId, teamId, privateKey);

  let sent = 0;
  for (const t of tokens) {
    const host = t.environment === "sandbox" ? "api.sandbox.push.apple.com" : "api.push.apple.com";
    const res = await fetch(`https://${host}/3/device/${t.token}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${jwt}`, "apns-topic": topic, "apns-push-type": "alert",
        // One banner per conversation instead of one per message.
        ...(row.conversation_id ? { "apns-collapse-id": row.conversation_id.slice(0, 64) } : {}),
      },
      body: JSON.stringify({
        aps: { alert, sound: "default", ...(row.conversation_id ? { "thread-id": row.conversation_id } : {}) },
        notification_id: id, kind: row.kind, conversation_id: row.conversation_id ?? undefined,
      }),
    });
    if (res.status === 410) {
      await admin.from("device_tokens").delete().eq("token", t.token);
    } else if (res.ok) {
      sent++;
    }
  }
  await markPushed();
  return Response.json({ sent });
});
