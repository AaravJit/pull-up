// End-to-end checks of the Supabase HTTP APIs the iOS app uses (Auth,
// PostgREST, Storage, Realtime, Edge Functions), run as real signed-in
// synthetic users against a whole Supabase stack. The pgTAP suites test the
// database from inside; this tests what a phone can actually reach.
//
// Three throwaway accounts: Ann and Ben are friends, Cat is an outsider.
// Every write one of them makes is checked against what the other two can
// and can't see. The accounts and their files are deleted at the end.
//
// Runs against the local stack in CI, and against a staging project from
// the "Supabase deploy" workflow. It refuses any other target: it creates
// and deletes users, so it must never point at production.
//
//   PULLUP_API_TARGET=local|staging
//   PULLUP_API_URL, PULLUP_API_ANON_KEY
//   PULLUP_API_SERVICE_ROLE_KEY  (only to create the test users; never in the app)
//
//   deno test --allow-env --allow-net supabase/tests/api/

import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2.45.4";
import { assert, assertEquals, assertExists, assertMatch } from "jsr:@std/assert@1";

const target = Deno.env.get("PULLUP_API_TARGET");
if (target !== "local" && target !== "staging") {
  throw new Error("Set PULLUP_API_TARGET to local or staging. These tests create and delete users.");
}
const need = (name: string): string => {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`${name} is not set`);
  return value;
};
const url = need("PULLUP_API_URL");
const anonKey = need("PULLUP_API_ANON_KEY");
const serviceKey = need("PULLUP_API_SERVICE_ROLE_KEY");

const noSession = { auth: { persistSession: false, autoRefreshToken: false } };
const admin = createClient(url, serviceKey, noSession);
const run = crypto.randomUUID().replaceAll("-", "").slice(0, 8);

type User = { name: string; id: string; db: SupabaseClient; email: string };
/** Every account this run created, from the moment it exists, so cleanup never misses one. */
type Created = { id: string; db?: SupabaseClient };

async function makeUser(name: string, created: Created[]): Promise<User> {
  const email = `pullup-api-${run}-${name}@example.com`;
  const password = `${crypto.randomUUID()}Aa1!`;
  const result = await admin.auth.admin.createUser({ email, password, email_confirm: true });
  if (result.error) throw result.error;
  const entry: Created = { id: result.data.user.id };
  created.push(entry);
  const db = createClient(url, anonKey, noSession);
  const signedIn = await db.auth.signInWithPassword({ email, password });
  if (signedIn.error) throw signedIn.error;
  entry.db = db;
  return { name, id: entry.id, db, email };
}

/** Removes every object under root, the same walk delete-account does. */
async function removeTree(bucket: string, root: string): Promise<string | null> {
  const queue = [root];
  while (queue.length > 0) {
    const prefix = queue.pop()!;
    const { data: entries, error } = await admin.storage.from(bucket).list(prefix, { limit: 1000 });
    if (error) return `listing ${bucket}/${prefix}: ${error.message}`;
    const files: string[] = [];
    for (const entry of entries ?? []) {
      if (entry.id === null) queue.push(`${prefix}/${entry.name}`);
      else files.push(`${prefix}/${entry.name}`);
    }
    if (files.length > 0) {
      const { error: removeError } = await admin.storage.from(bucket).remove(files);
      if (removeError) return `removing from ${bucket}/${prefix}: ${removeError.message}`;
    }
  }
  return null;
}

/** Fallback when delete-account fails: the account's files, then the account. */
async function removeAccount(id: string): Promise<string[]> {
  const problems: string[] = [];
  const { data: conversations, error } = await admin.from("conversations").select("id").or(`user_a.eq.${id},user_b.eq.${id}`);
  if (error) problems.push(`listing conversations: ${error.message}`);
  for (const c of conversations ?? []) {
    const problem = await removeTree("dm-media", c.id);
    if (problem) problems.push(problem);
  }
  for (const bucket of ["avatars", "vehicle-media", "post-media"]) {
    const problem = await removeTree(bucket, id);
    if (problem) problems.push(problem);
  }
  const deleted = await admin.auth.admin.deleteUser(id);
  if (deleted.error) problems.push(`deleting auth user ${id}: ${deleted.error.message}`);
  return problems;
}

/** Data from a call that must succeed. */
function ok<T>(result: { data: T; error: unknown }, what: string): NonNullable<T> {
  if (result.error) throw new Error(`${what}: ${JSON.stringify(result.error)}`);
  // Writes without .select() return null; callers only read what they selected.
  return result.data as NonNullable<T>;
}

/** A call that must be refused outright. Returns the Postgres error code. */
function refused(result: { error: unknown }, what: string): string {
  assert(result.error, `${what} should have been refused`);
  return (result.error as { code?: string }).code ?? "";
}

/** An update or delete row-level security must filter down to nothing. */
function untouched(result: { data: unknown[] | null; error: unknown }, what: string) {
  assertEquals(result.error, null, what);
  assertEquals(result.data ?? [], [], `${what} should affect no rows`);
}

const jpeg = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00, 0xff, 0xd9]);
const upload = (u: User, bucket: string, path: string) =>
  u.db.storage.from(bucket).upload(path, jpeg, { contentType: "image/jpeg", upsert: true });
const canOpen = async (u: User, bucket: string, path: string) =>
  !(await u.db.storage.from(bucket).createSignedUrl(path, 60)).error;

const wait = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

async function eventually(what: string, check: () => Promise<boolean>, timeoutMs = 10_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await check()) return;
    await wait(250);
  }
  throw new Error(`timed out waiting for ${what}`);
}

const notificationKinds = async (u: User) =>
  ok(await u.db.from("notifications").select("kind, actor_id").eq("recipient_id", u.id), "notifications")
    .map((n: { kind: string; actor_id: string | null }) => `${n.kind}:${n.actor_id}`);

/** A 2-minute, 1 Hz drive heading north at about 15 m/s, in the app's encoding. */
function track() {
  const points: number[][] = [];
  for (let t = 0; t <= 120; t++) {
    const speed = 15 + Math.sin(t / 10) * 0.5;
    points.push([t, 37.33 + (t * 15) / 111_320, -122.03, 20 + t * 0.1, speed, 5 + (t % 7) * 0.5, 4, 0.5]);
  }
  return points;
}

Deno.test({
  name: "two accounts against the hosted APIs",
  sanitizeOps: false,
  sanitizeResources: false,
  async fn(t) {
    const created: Created[] = [];
    const users: User[] = [];
    let finished = false;
    try {
      const ann = await makeUser("ann", created);
      const ben = await makeUser("ben", created);
      const cat = await makeUser("cat", created);
      users.push(ann, ben, cat);

      await t.step("signed out, the API serves nothing", async () => {
        const anon = createClient(url, anonKey, noSession);
        refused(await anon.from("profiles").select("id").limit(1), "anon profile read");
        refused(await anon.rpc("get_profile", { p_user: ann.id }), "anon get_profile");
        refused(await anon.from("vehicles").select("id").limit(1), "anon vehicle read");
      });

      await t.step("profiles and onboarding", async () => {
        for (const u of users) {
          const row = ok(await u.db.from("profiles").select("username, onboarded_at").eq("id", u.id).single(), "own profile");
          assertMatch(row.username, /^driver_[0-9a-f]{10}$/, "new accounts get a placeholder username");
          assertEquals(row.onboarded_at, null);
        }
        const name = (u: User) => `pu${u.name}${run}`;
        assertEquals(ok(await ann.db.rpc("username_status", { p_username: name(ann) }), "username_status"), "available");
        for (const u of users) {
          ok(await u.db.rpc("claim_username", { p_username: name(u), p_display_name: `Test ${u.name}` }), "claim_username");
          ok(await u.db.rpc("complete_onboarding"), "complete_onboarding");
        }
        assertEquals(refused(await ben.db.rpc("claim_username", { p_username: name(ann) }), "taking Ann's name"), "23505");
        untouched(await ben.db.from("profiles").update({ display_name: "hijacked" }).eq("id", ann.id).select(), "Ben editing Ann");
        const annRow = ok(await ann.db.from("profiles").select("display_name").eq("id", ann.id).single(), "Ann's profile");
        assertEquals(annRow.display_name, "Test ann");

        ok(await ann.db.storage.from("avatars").upload(`${ann.id}/avatar-${run}.jpg`, jpeg, { contentType: "image/jpeg" }), "avatar");
        refused(await upload(ben, "avatars", `${ann.id}/avatar-evil.jpg`), "Ben writing into Ann's avatar folder");
      });

      // Shared across the steps below.
      const ids: Record<string, string> = {};

      await t.step("garage visibility and photos", async () => {
        const m3 = ok(await ann.db.from("vehicles").insert({
          owner_id: ann.id, kind: "car", make: "BMW", model: "M3", year: 2021, visibility: "public",
        }).select("id").single(), "public car");
        const bike = ok(await ann.db.from("vehicles").insert({
          owner_id: ann.id, kind: "motorcycle", make: "Ducati", model: "Monster", year: 2019, visibility: "private",
        }).select("id").single(), "private bike");
        ids.m3 = m3.id;
        ids.bike = bike.id;

        const seenByBen = ok(await ben.db.from("vehicles").select("id").eq("owner_id", ann.id), "Ben reads Ann's garage");
        assertEquals(seenByBen.map((v: { id: string }) => v.id), [m3.id], "Ben sees only the public car");
        refused(await ben.db.from("vehicles").insert({ owner_id: ann.id, kind: "car", make: "X", model: "Y", year: 2000 }), "Ben adding to Ann's garage");
        untouched(await ben.db.from("vehicles").update({ nickname: "mine now" }).eq("id", m3.id).select(), "Ben editing Ann's car");

        const photo = `${ann.id}/${bike.id}/${run}.jpg`;
        ok(await upload(ann, "vehicle-media", photo), "bike photo");
        ok(await ann.db.from("vehicle_photos").insert({ vehicle_id: bike.id, storage_path: photo }), "bike photo row");
        assert(await canOpen(ann, "vehicle-media", photo), "Ann opens her photo");
        assert(!(await canOpen(ben, "vehicle-media", photo)), "Ben can't open a private vehicle's photo");
        refused(await upload(ben, "vehicle-media", `${ann.id}/${bike.id}/evil.jpg`), "Ben writing into Ann's vehicle folder");
      });

      await t.step("drive upload, validation and privacy", async () => {
        const id = crypto.randomUUID();
        ids.drive = id;
        const started = new Date(Date.now() - 10 * 60_000);
        const drive = {
          id, owner_id: ann.id, vehicle_id: ids.m3, title: "Test loop",
          started_at: started.toISOString(), ended_at: new Date(started.getTime() + 120_000).toISOString(),
          distance_m: 1800, moving_s: 120, stopped_s: 0, elapsed_s: 120,
          top_speed_mps: 15.5, avg_moving_speed_mps: 15, visibility: "private",
        };
        // The app retries uploads; the same drive twice must stay one drive.
        for (let i = 0; i < 2; i++) {
          ok(await ann.db.from("drives").upsert(drive, { onConflict: "id", ignoreDuplicates: true }), "drive upload");
        }
        ok(await ann.db.from("drive_tracks").insert({ drive_id: id, owner_id: ann.id, points: track() }), "track upload");
        const rows = ok(await ann.db.from("drives").select("vehicle_id, validation_status, validation_notes").eq("id", id), "own drive");
        assertEquals(rows.length, 1);
        assertEquals(rows[0].vehicle_id, ids.m3, "the drive stays on the vehicle picked at Start Drive");
        assertEquals(rows[0].validation_status, "validated", `notes: ${rows[0].validation_notes}`);

        assertEquals(ok(await ben.db.from("drives").select("id").eq("id", id), "Ben reads drive"), [], "private drive");
        assertEquals(ok(await ben.db.from("drive_tracks").select("drive_id").eq("drive_id", id), "Ben reads track"), [], "raw GPS track");
        refused(await ben.db.rpc("share_drive_route", { p_drive: id }), "Ben sharing Ann's route");
        refused(await ben.db.from("drives").insert({ ...drive, id: crypto.randomUUID() }), "Ben uploading a drive as Ann");
        untouched(await ben.db.from("drives").delete().eq("id", id).select(), "Ben deleting Ann's drive");
      });

      await t.step("follows and notifications", async () => {
        ok(await ben.db.from("follows").insert({ follower_id: ben.id, followee_id: ann.id }), "Ben follows Ann");
        ok(await ann.db.from("follows").insert({ follower_id: ann.id, followee_id: ben.id }), "Ann follows Ben");
        refused(await cat.db.from("follows").insert({ follower_id: ann.id, followee_id: cat.id }), "Cat making Ann follow her");
        assert((await notificationKinds(ann)).includes(`follow:${ben.id}`), "Ann is told Ben followed her");
        assertEquals(ok(await cat.db.from("notifications").select("id").eq("recipient_id", ann.id), "Cat reads Ann's bell"), []);
        untouched(await cat.db.from("notifications").update({ read_at: new Date().toISOString() }).eq("recipient_id", ann.id).select(), "Cat marking Ann's bell read");
      });

      await t.step("feed posts, likes and comments", async () => {
        const post = ok(await ann.db.from("posts").insert({ author_id: ann.id, caption: "API test", visibility: "public" }).select("id").single(), "post");
        const secret = ok(await ann.db.from("posts").insert({ author_id: ann.id, caption: "only me", visibility: "private" }).select("id").single(), "private post");
        ids.post = post.id;

        const benSees = ok(await ben.db.from("posts").select("id").eq("author_id", ann.id), "Ben's view of Ann's posts")
          .map((p: { id: string }) => p.id);
        assert(benSees.includes(post.id));
        assert(!benSees.includes(secret.id), "private post hidden");

        ok(await ben.db.from("likes").insert({ post_id: post.id, user_id: ben.id }), "like");
        ok(await ben.db.from("comments").insert({ post_id: post.id, author_id: ben.id, body: "Nice" }), "comment");
        refused(await cat.db.from("comments").insert({ post_id: post.id, author_id: ben.id, body: "as Ben" }), "Cat commenting as Ben");
        refused(await ben.db.from("likes").insert({ post_id: secret.id, user_id: ben.id }), "liking a post Ben can't see");
        untouched(await ben.db.from("posts").delete().eq("id", post.id).select(), "Ben deleting Ann's post");
        const kinds = await notificationKinds(ann);
        assert(kinds.includes(`like:${ben.id}`) && kinds.includes(`comment:${ben.id}`), `Ann's bell: ${kinds}`);
      });

      await t.step("meets, RSVPs and cancellation", async () => {
        const start = new Date(Date.now() + 24 * 3_600_000);
        const meet = ok(await ann.db.from("meets").insert({
          host_id: ann.id, title: "API test meet", venue_name: "Lot 7", lat: 37.33, lon: -122.03,
          starts_at: start.toISOString(), ends_at: new Date(start.getTime() + 2 * 3_600_000).toISOString(),
        }).select("id").single(), "meet");
        ok(await ben.db.from("meet_rsvps").insert({ meet_id: meet.id, user_id: ben.id, status: "going", show_me: true }), "Ben RSVPs");
        refused(await cat.db.from("meet_rsvps").insert({ meet_id: meet.id, user_id: ben.id, status: "going", show_me: true }), "Cat RSVPing for Ben");
        const attendees = ok(await ann.db.rpc("meet_attendees", { p_meet: meet.id }), "attendees") as { id: string }[];
        assert(attendees.some((a) => a.id === ben.id), "Ben shows as going");

        untouched(await ben.db.from("meets").update({ cancelled_at: new Date().toISOString() }).eq("id", meet.id).select(), "Ben cancelling Ann's meet");
        ok(await ann.db.from("meets").update({ cancelled_at: new Date().toISOString() }).eq("id", meet.id), "Ann cancels");
        assert((await notificationKinds(ben)).includes(`meet_cancelled:${ann.id}`), "Ben is told the meet is off");
      });

      await t.step("direct messages, requests, realtime and photos", async () => {
        const conversation = ok(await ben.db.rpc("start_conversation", { p_user: ann.id }), "Ben starts a chat") as string;
        ids.conversation = conversation;

        // Ann listens the way the app does. Cat listens too and must hear nothing.
        const heard: Record<string, string[]> = { ann: [], cat: [] };
        const payloads: Record<string, unknown[]> = { ann: [], cat: [] };
        const channels = [ann, cat].map((u) =>
          u.db.channel(`dm-${run}-${u.name}`)
            .on("postgres_changes", { event: "*", schema: "public", table: "messages" }, (change) => {
              payloads[u.name].push(change);
              heard[u.name].push((change.new as { id?: string }).id ?? "");
            })
        );
        for (const [i, u] of [ann, cat].entries()) {
          u.db.realtime.setAuth((await u.db.auth.getSession()).data.session!.access_token);
          await new Promise<void>((resolve, reject) => {
            channels[i].subscribe((status, err) => {
              if (status === "SUBSCRIBED") resolve();
              if (status === "CHANNEL_ERROR" || status === "TIMED_OUT") reject(err ?? new Error(status));
            });
          });
        }
        // SUBSCRIBED can arrive before the server has attached the Postgres
        // listener, and changes in that gap aren't delivered, so give it a
        // moment before sending.
        await wait(3_000);

        const first = crypto.randomUUID();
        ok(await ben.db.from("messages").insert({ id: first, conversation_id: conversation, sender_id: ben.id, body: "Hi Ann" }), "Ben sends");
        await eventually("Ann's realtime delivery", async () => heard.ann.includes(first))
          .catch((error) => { throw new Error(`${error.message}; Ann heard ${JSON.stringify(payloads.ann)}`); });
        await wait(2_000);
        assertEquals(heard.cat, [], `Cat's subscription carries nothing from a chat she isn't in: ${JSON.stringify(payloads.cat)}`);
        await Promise.all([ann, cat].map((u, i) => u.db.removeChannel(channels[i])));

        // Retrying a send after a lost response is a no-op, not a duplicate.
        ok(await ben.db.from("messages").upsert({ id: first, conversation_id: conversation, sender_id: ben.id, body: "Hi Ann" },
          { onConflict: "id", ignoreDuplicates: true }), "retry");
        assertEquals(ok(await ann.db.from("messages").select("id").eq("conversation_id", conversation), "Ann's view").length, 1);

        assertEquals(ok(await cat.db.from("messages").select("id").eq("conversation_id", conversation), "Cat reads"), []);
        refused(await cat.db.from("messages").insert({ conversation_id: conversation, sender_id: cat.id, body: "hey" }), "Cat posting in their chat");
        refused(await cat.db.from("messages").insert({ conversation_id: conversation, sender_id: ben.id, body: "as Ben" }), "Cat posting as Ben");

        const photoID = crypto.randomUUID();
        const photo = `${conversation}/${ben.id}/${photoID}.jpg`;
        ok(await upload(ben, "dm-media", photo), "DM photo");
        ok(await ben.db.from("messages").insert({
          id: photoID, conversation_id: conversation, sender_id: ben.id, media_path: photo, media_width: 1, media_height: 1,
        }), "photo message");
        assert(await canOpen(ann, "dm-media", photo), "Ann opens the photo");
        assert(!(await canOpen(cat, "dm-media", photo)), "Cat can't open it");
        refused(await upload(cat, "dm-media", `${conversation}/${cat.id}/x.jpg`), "Cat uploading into their chat");

        ok(await ann.db.from("message_reactions").upsert({ message_id: first, user_id: ann.id, emoji: "🔥" }, { onConflict: "message_id,user_id" }), "reaction");
        refused(await cat.db.from("message_reactions").insert({ message_id: first, user_id: cat.id, emoji: "👎" }), "Cat reacting");

        ok(await ann.db.rpc("mark_conversation_read", { p_conversation: conversation }), "read");
        assertExists(ok(await ben.db.rpc("peer_read_at", { p_conversation: conversation }), "read receipt"), "Ben sees Ann read it");
        refused(await ann.db.rpc("unsend_message", { p_message: first }), "Ann unsending Ben's message");
        ok(await ben.db.rpc("unsend_message", { p_message: first }), "Ben unsends");
        const unsent = ok(await ann.db.from("messages").select("body, unsent_at").eq("id", first).single(), "unsent message");
        assertExists(unsent.unsent_at);
        assertEquals(unsent.body, "", "the text is gone for Ann too");

        for (let i = 0; i < 5; i++) {
          ok(await ann.db.from("messages").insert({ conversation_id: conversation, sender_id: ann.id, body: `page ${i}` }), "page");
        }
        const page = ok(await ben.db.from("messages").select("id, created_at").eq("conversation_id", conversation)
          .order("created_at", { ascending: false }).limit(3), "first page");
        assertEquals(page.length, 3);
        const older = ok(await ben.db.from("messages").select("id").eq("conversation_id", conversation)
          .lt("created_at", page[2].created_at).order("created_at", { ascending: false }).limit(3), "next page");
        assertEquals(older.length, 3);

        ok(await ann.db.rpc("set_conversation_muted", { p_conversation: conversation, p_muted: true }), "mute");
        // Muting only ever touches the caller's own membership, so Cat's call is a no-op.
        ok(await cat.db.rpc("set_conversation_muted", { p_conversation: conversation, p_muted: false }), "Cat's unmute");
        const membership = ok(await ann.db.from("conversation_members").select("muted")
          .eq("conversation_id", conversation).eq("user_id", ann.id).single(), "Ann's membership");
        assertEquals(membership.muted, true, "Ann's chat stays muted");

        // Ann doesn't follow Cat, so Cat's message is a request.
        const request = ok(await cat.db.rpc("start_conversation", { p_user: ann.id }), "Cat starts a chat") as string;
        ids.request = request;
        ok(await cat.db.from("messages").insert({ conversation_id: request, sender_id: cat.id, body: "Hello?" }), "request message");
        const requests = ok(await ann.db.rpc("inbox", { p_state: "request" }), "requests") as { conversation_id: string }[];
        assert(requests.some((r) => r.conversation_id === request), "Cat's chat is in Ann's requests");
        const active = ok(await ann.db.rpc("inbox", { p_state: "active" }), "inbox") as { conversation_id: string }[];
        assert(active.some((r) => r.conversation_id === conversation) && !active.some((r) => r.conversation_id === request));
        // Until Ann answers, Cat gets three messages.
        for (const body of ["Hello??", "Hello???"]) {
          ok(await cat.db.from("messages").insert({ conversation_id: request, sender_id: cat.id, body }), "request message");
        }
        assertEquals(refused(await cat.db.from("messages").insert({ conversation_id: request, sender_id: cat.id, body: "Hello????" }), "a fourth unanswered request message"), "54000");
        ok(await ann.db.rpc("respond_to_request", { p_conversation: request, p_accept: false }), "Ann declines");
      });

      await t.step("shared items follow the owner's current privacy", async () => {
        const preview = async (kind: string, id: string) =>
          (ok(await ben.db.rpc("shared_preview", { p_kind: kind, p_id: id }), "preview") as { available: boolean }).available;
        for (const [kind, id] of [["vehicle", ids.bike], ["post", ids.post], ["drive", ids.drive]]) {
          ok(await ann.db.from("messages").insert({ conversation_id: ids.conversation, sender_id: ann.id, shared_kind: kind, shared_id: id }), `share ${kind}`);
        }
        assertEquals(await preview("vehicle", ids.bike), false, "a private vehicle stays private when shared");
        assertEquals(await preview("drive", ids.drive), false, "a private drive stays private when shared");
        assertEquals(await preview("post", ids.post), true);

        ok(await ann.db.from("vehicles").update({ visibility: "public" }).eq("id", ids.bike), "bike public");
        assertEquals(await preview("vehicle", ids.bike), true);
        ok(await ann.db.from("vehicles").update({ visibility: "private" }).eq("id", ids.bike), "bike private again");
        assertEquals(await preview("vehicle", ids.bike), false, "making it private again closes the old message too");

        ok(await ann.db.from("posts").delete().eq("id", ids.post), "Ann deletes the post");
        assertEquals(await preview("post", ids.post), false, "a deleted post is gone from the chat");
      });

      await t.step("blocking", async () => {
        ok(await ann.db.from("blocks").insert({ blocker_id: ann.id, blocked_id: cat.id }), "Ann blocks Cat");
        refused(await cat.db.rpc("start_conversation", { p_user: ann.id }), "Cat messaging Ann");
        refused(await cat.db.from("messages").insert({ conversation_id: ids.request, sender_id: cat.id, body: "still here" }), "Cat in the old chat");
        assertEquals(ok(await cat.db.from("vehicles").select("id").eq("owner_id", ann.id), "Cat reads Ann's garage"), [], "blocked");
        untouched(await cat.db.from("blocks").delete().eq("blocker_id", ann.id).select(), "Cat lifting Ann's block");
        assertEquals(ok(await ann.db.from("blocks").select("blocked_id"), "Ann's blocks").length, 1);
      });

      await t.step("push tokens move with the account on a shared phone", async () => {
        const token = "ab".repeat(32);
        ok(await ann.db.rpc("register_device_token", { p_token: token, p_environment: "sandbox" }), "Ann registers");
        ok(await ben.db.rpc("register_device_token", { p_token: token, p_environment: "sandbox" }), "Ben signs in on the same phone");
        assertEquals(ok(await ann.db.from("device_tokens").select("token"), "Ann's tokens"), [], "Ann no longer gets this phone's pushes");
        assertEquals(ok(await ben.db.from("device_tokens").select("token"), "Ben's tokens").length, 1);
        refused(await ann.db.from("device_tokens").insert({ token: "cd".repeat(32), user_id: ben.id, platform: "ios" }), "writing tokens directly");
        ok(await ben.db.rpc("unregister_device_token", { p_token: token }), "sign-out unregisters");
        assertEquals(ok(await ben.db.from("device_tokens").select("token"), "Ben's tokens"), []);
      });

      await t.step("Pro can't be granted from the phone", async () => {
        const isPro = async () =>
          (ok(await ben.db.rpc("my_entitlement"), "my_entitlement") as { is_pro: boolean }[]).some((e) => e.is_pro);
        assertEquals(await isPro(), false);
        refused(await ben.db.from("entitlements").insert({
          user_id: ben.id, product_id: "app.pullup.pro.yearly", original_transaction_id: run, status: "active",
          environment: "Production", signed_at: new Date().toISOString(),
        }), "writing an entitlement directly");
        const forged = await ben.db.functions.invoke("verify-subscription", { body: { signed_transaction: "e30.e30.sig" } });
        assert(forged.error, "a forged transaction is rejected");
        assertEquals(await isPro(), false, "still no Pro");
      });

      await t.step("account deletion removes the account and its data", async () => {
        const deleted = await cat.db.functions.invoke("delete-account", { body: {} });
        assertEquals(deleted.error, null, `delete-account: ${deleted.error}`);
        assertEquals((deleted.data as { deleted?: boolean }).deleted, true);
        users.splice(users.indexOf(cat), 1);
        created.splice(created.findIndex((c) => c.id === cat.id), 1);
        assert((await admin.auth.admin.getUserById(cat.id)).error, "the auth user is gone");
        assertEquals(ok(await ann.db.from("profiles").select("id").eq("id", cat.id), "Cat's profile"), []);
        const requests = ok(await ann.db.rpc("inbox", { p_state: "request" }), "requests") as { conversation_id: string }[];
        assert(!requests.some((r) => r.conversation_id === ids.request), "her conversations went with her");
      });
      finished = true;
    } finally {
      // Same path as a person deleting their account, so Storage is cleaned
      // too. If the function fails, or the account never got signed in, the
      // service role removes its files and the account, and the run fails so
      // nothing is left behind unnoticed.
      const problems: string[] = [];
      for (const c of created) {
        const result = c.db
          ? await c.db.functions.invoke("delete-account", { body: {} }).catch((error) => ({ error }))
          : { error: "never signed in" };
        if (!result.error) continue;
        problems.push(`delete-account for ${c.id} failed (${result.error instanceof Error ? result.error.message : String(result.error)}); removed by the service role instead`);
        problems.push(...await removeAccount(c.id));
      }
      if (problems.length > 0) {
        if (finished) throw new Error(`Cleanup:\n${problems.join("\n")}`);
        console.error(`Cleanup:\n${problems.join("\n")}`);
      }
    }
  },
});
