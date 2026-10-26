// deno test supabase/functions/_shared/
// delete-account's steps against fakes: in-memory Storage, a stubbed Auth
// and a stubbed Apple with a throwaway P-256 key. No network, no real keys.
import { type AppleConfig, appleConfig, clientSecret, pemToDer } from "./apple.ts";
import { deleteAccount, type DeleteAccountDeps, type Identity } from "./delete_account.ts";
import { assert, assertEquals, FakeStorage, fakeSleep } from "./test_fakes.ts";

const uid = "0b6f3e3e-9c1d-4b6a-8f6e-2a1d3c4b5e6f";
const other = "aaaaaaaa-0000-0000-0000-00000000000b";
const conversation = "cccccccc-0000-0000-0000-000000000001";
const appleSub = "001234.abcdef0123456789.0042";

const keys = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", keys.privateKey));
const pem = `-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...pkcs8)).replace(/(.{64})/g, "$1\n")}\n-----END PRIVATE KEY-----`;
const apple: AppleConfig = { teamId: "TEAM123456", keyId: "KEY1234567", privateKey: pem, clientId: "app.pullup.ios" };

const b64url = (bytes: Uint8Array) => btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const b64urlDecode = (text: string) =>
  Uint8Array.from(atob(text.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(text.length / 4) * 4, "=")), (c) => c.charCodeAt(0));
const idToken = (sub: string) => `e30.${b64url(new TextEncoder().encode(JSON.stringify({ sub, aud: apple.clientId })))}.c2ln`;

function seededStorage(): FakeStorage {
  const storage = new FakeStorage();
  storage.add("avatars", `${uid}/avatar-1.jpg`, `${other}/avatar.jpg`);
  storage.add("vehicle-media", ...Array.from({ length: 1200 }, (_, i) => `${uid}/car-${Math.floor(i / 400)}/${i}.jpg`));
  storage.add("post-media", `${uid}/post-1/0.jpg`, `${uid}/post-1/1.mov`, `${other}/post-9/0.jpg`);
  storage.add("dm-media", `${conversation}/${uid}/m1.jpg`, `${conversation}/${other}/m2.jpg`, `dddddddd-0000-0000-0000-000000000009/${other}/m3.jpg`);
  return storage;
}

type AppleCall = { url: string; form: Record<string, string> };

/** A stubbed appleid.apple.com. `revoke` lists the statuses to answer, in turn. */
function fakeApple(options: { token?: number; revoke?: number[]; sub?: string } = {}) {
  const calls: AppleCall[] = [];
  const revokeStatuses = [...(options.revoke ?? [200])];
  const impl = async (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const url = String(input);
    assertEquals(new Headers(init?.headers).get("content-type"), "application/x-www-form-urlencoded", "form encoded");
    const form = Object.fromEntries(new URLSearchParams(String(init?.body)));
    calls.push({ url, form });
    events.push(url.endsWith("/auth/token") ? "apple:token" : "apple:revoke");
    if (url === "https://appleid.apple.com/auth/token") {
      const status = options.token ?? 200;
      if (status !== 200) return new Response(JSON.stringify({ error: "invalid_grant" }), { status });
      return Response.json({
        access_token: "access-xyz", token_type: "Bearer", expires_in: 3600,
        refresh_token: "refresh-abc", id_token: idToken(options.sub ?? appleSub),
      });
    }
    if (url === "https://appleid.apple.com/auth/revoke") {
      return new Response(null, { status: revokeStatuses.shift() ?? 200 });
    }
    return new Response("unexpected", { status: 404 });
  };
  return { calls, impl };
}

let events: string[] = [];

function deps(storage: FakeStorage, overrides: Partial<DeleteAccountDeps> & { identities?: Identity[] } = {}) {
  const logs: string[] = [];
  const deleted: string[] = [];
  const instrumented = new Proxy(storage, {
    get(target, prop) {
      if (prop !== "from") return Reflect.get(target, prop);
      return (bucket: string) => {
        const client = target.from(bucket);
        return {
          list: client.list,
          remove: (paths: string[]) => {
            events.push(`remove:${bucket}`);
            return client.remove(paths);
          },
        };
      };
    },
  });
  const d: DeleteAccountDeps = {
    user: () => Promise.resolve({ user: { id: uid, identities: overrides.identities ?? [{ provider: "email", id: uid }] }, error: null }),
    conversationIds: () => Promise.resolve({ ids: [conversation], error: null }),
    storage: instrumented,
    deleteUser: (id) => {
      events.push("deleteUser");
      deleted.push(id);
      return Promise.resolve({ error: null });
    },
    apple: null,
    cleanup: { sleep: fakeSleep().sleep },
    appleRetry: { sleep: fakeSleep().sleep },
    log: (line) => logs.push(line),
    ...overrides,
  };
  return { d, logs, deleted };
}

const appleIdentity: Identity[] = [{ provider: "apple", id: appleSub, identity_data: { sub: appleSub, email: "x@privaterelay.appleid.com" } }];

function assertOnlyOthersLeft(storage: FakeStorage) {
  assertEquals(storage.files("avatars"), [`${other}/avatar.jpg`]);
  assertEquals(storage.files("vehicle-media"), []);
  assertEquals(storage.files("post-media"), [`${other}/post-9/0.jpg`]);
  assertEquals(storage.files("dm-media"), [`dddddddd-0000-0000-0000-000000000009/${other}/m3.jpg`], "only conversations they weren't in");
}

Deno.test("deletes every file the account owns, then the account", async () => {
  events = [];
  const storage = seededStorage();
  const { d, deleted } = deps(storage);
  const result = await deleteAccount({}, d);
  assertEquals(result.status, 200);
  assertEquals(result.body, { deleted: true, removed_files: 1205, apple_revoked: null, apple_reason: null });
  assertOnlyOthersLeft(storage);
  assertEquals(deleted, [uid]);
  assertEquals(events.at(-1), "deleteUser", "the auth user goes last");
});

Deno.test("a storage failure keeps the account and says so; calling again finishes", async () => {
  events = [];
  const storage = seededStorage();
  storage.fail({ op: "list", bucket: "post-media", times: Infinity, error: { message: "Service Unavailable", status: 503 } });
  const { d, deleted, logs } = deps(storage);
  const first = await deleteAccount({}, d);
  assertEquals(first.status, 503);
  assertEquals(first.body.deleted, false);
  assertEquals(first.body.error, "storage_incomplete");
  assert(String(first.body.message).includes("Try again"), "a message the app shows");
  assertEquals(deleted, [], "the account stays so a retry can find its files");
  assert(logs.some((l) => l.includes("Service Unavailable")), "logged");

  storage.faults.length = 0;
  const second = await deleteAccount({}, d);
  assertEquals(second.status, 200);
  assertEquals(second.body.deleted, true);
  assertOnlyOthersLeft(storage);
  assertEquals(deleted, [uid]);
});

Deno.test("conversations that can't be listed stop the deletion", async () => {
  const storage = seededStorage();
  const { d, deleted } = deps(storage, { conversationIds: () => Promise.resolve({ ids: [], error: "timeout" }) });
  const result = await deleteAccount({}, d);
  assertEquals(result.status, 503);
  assertEquals(deleted, []);
  assertEquals(storage.calls, [], "no file touched");
});

Deno.test("a failed auth deletion is an error, and a retry completes it", async () => {
  const storage = seededStorage();
  let fail = true;
  const { d } = deps(storage, {
    deleteUser: () => Promise.resolve({ error: fail ? { message: "Database error deleting user" } : null }),
  });
  const first = await deleteAccount({}, d);
  assertEquals(first.status, 500);
  assertEquals(first.body.deleted, false);
  fail = false;
  const second = await deleteAccount({}, d);
  assertEquals(second.status, 200);
  assertEquals(second.body.removed_files, 0, "files were already gone");
});

Deno.test("a retry after the account is gone reports it deleted; a bad token doesn't", async () => {
  const storage = seededStorage();
  const gone = deps(storage, {
    user: () => Promise.resolve({ user: null, error: { message: "User from sub claim in JWT does not exist", code: "user_not_found", status: 403 } }),
  });
  const result = await deleteAccount({}, gone.d);
  assertEquals(result.status, 200);
  assertEquals(result.body.already_deleted, true);
  assertEquals(storage.calls, []);

  const invalid = deps(storage, { user: () => Promise.resolve({ user: null, error: { message: "invalid JWT", code: "bad_jwt", status: 403 } }) });
  assertEquals((await deleteAccount({}, invalid.d)).status, 401);
  assertEquals(invalid.deleted, []);
});

Deno.test("Sign in with Apple: code exchanged first, token revoked after the account is deleted", async () => {
  events = [];
  const storage = seededStorage();
  const appleStub = fakeApple();
  const { d, logs } = deps(storage, { identities: appleIdentity, apple, fetch: appleStub.impl });
  const result = await deleteAccount({ apple_authorization_code: "c0de.one-time" }, d);
  assertEquals(result.status, 200);
  assertEquals(result.body.apple_revoked, true);
  assertEquals(result.body.apple_reason, null);
  assertEquals(events[0], "apple:token");
  assertEquals(events.slice(-2), ["deleteUser", "apple:revoke"]);

  const [token, revoke] = appleStub.calls;
  assertEquals(token.url, "https://appleid.apple.com/auth/token");
  assertEquals(
    { ...token.form, client_secret: "-" },
    { client_id: "app.pullup.ios", client_secret: "-", code: "c0de.one-time", grant_type: "authorization_code" },
  );
  assertEquals(revoke.url, "https://appleid.apple.com/auth/revoke");
  assertEquals(
    { ...revoke.form, client_secret: "-" },
    { client_id: "app.pullup.ios", client_secret: "-", token: "refresh-abc", token_type_hint: "refresh_token" },
  );
  for (const call of appleStub.calls) await assertValidClientSecret(call.form.client_secret);
  const logged = logs.join("\n");
  for (const secret of ["c0de.one-time", "refresh-abc", "access-xyz", "PRIVATE KEY", btoa(String.fromCharCode(...pkcs8)).slice(0, 40)]) {
    assert(!logged.includes(secret), `the log doesn't contain ${secret.slice(0, 12)}`);
  }
});

async function assertValidClientSecret(jwt: string) {
  const [header, claims, signature] = jwt.split(".");
  const h = JSON.parse(new TextDecoder().decode(b64urlDecode(header)));
  const c = JSON.parse(new TextDecoder().decode(b64urlDecode(claims)));
  assertEquals(h, { alg: "ES256", kid: "KEY1234567" });
  assertEquals([c.iss, c.aud, c.sub], ["TEAM123456", "https://appleid.apple.com", "app.pullup.ios"]);
  assert(Number.isInteger(c.iat) && c.exp - c.iat === 300, "five-minute lifetime");
  assert(Math.abs(c.iat - Date.now() / 1000) < 60, "issued now");
  const sig = b64urlDecode(signature);
  assertEquals(sig.length, 64, "raw r||s, as JWS ES256 requires");
  const ok = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    keys.publicKey,
    sig,
    new TextEncoder().encode(`${header}.${claims}`),
  );
  assert(ok, "signed with the Sign in with Apple key");
}

Deno.test("Apple revocation retries a 5xx, and a final refusal doesn't undo the deletion", async () => {
  const retried = fakeApple({ revoke: [503, 200] });
  const sleeps = fakeSleep();
  const a = deps(seededStorage(), { identities: appleIdentity, apple, fetch: retried.impl, appleRetry: { sleep: sleeps.sleep } });
  const ok = await deleteAccount({ apple_authorization_code: "code" }, a.d);
  assertEquals(ok.body.apple_revoked, true);
  assertEquals(retried.calls.filter((c) => c.url.endsWith("/revoke")).length, 2);
  assertEquals(sleeps.waits, [500]);

  const refused = fakeApple({ revoke: [400] });
  const b = deps(seededStorage(), { identities: appleIdentity, apple, fetch: refused.impl });
  const result = await deleteAccount({ apple_authorization_code: "code" }, b.d);
  assertEquals(result.status, 200);
  assertEquals([result.body.deleted, result.body.apple_revoked, result.body.apple_reason], [true, false, "revoke_failed"]);
  assertEquals(refused.calls.filter((c) => c.url.endsWith("/revoke")).length, 1, "a 4xx isn't retried");
  assertEquals(b.deleted, [uid]);
});

Deno.test("Apple not configured: deleted, revocation skipped, logged without secrets", async () => {
  const stub = fakeApple();
  const { d, logs, deleted } = deps(seededStorage(), { identities: appleIdentity, apple: null, fetch: stub.impl });
  const result = await deleteAccount({ apple_authorization_code: "code-123" }, d);
  assertEquals([result.body.deleted, result.body.apple_revoked, result.body.apple_reason], [true, false, "not_configured"]);
  assertEquals(deleted, [uid]);
  assertEquals(stub.calls, []);
  assert(logs.some((l) => l.includes("APPLE_* secrets are not configured")), "logged");
  assert(!logs.join("\n").includes("code-123"), "the code isn't logged");
  assertEquals(appleConfig(() => undefined), null);
  assertEquals(appleConfig((name) => (name === "APPLE_KEY_ID" ? undefined : "x")), null, "all four are needed");
});

Deno.test("Apple: no code, a refused code, or another Apple Account's code", async () => {
  const none = fakeApple();
  const a = deps(seededStorage(), { identities: appleIdentity, apple, fetch: none.impl });
  const noCode = await deleteAccount({}, a.d);
  assertEquals([noCode.body.deleted, noCode.body.apple_reason], [true, "no_code"]);
  assertEquals(none.calls, []);

  const bad = fakeApple({ token: 400 });
  const b = deps(seededStorage(), { identities: appleIdentity, apple, fetch: bad.impl });
  const refused = await deleteAccount({ apple_authorization_code: "expired" }, b.d);
  assertEquals([refused.body.deleted, refused.body.apple_reason], [true, "exchange_failed"]);
  assertEquals(bad.calls.length, 1, "no revoke without a token");

  const elsewhere = fakeApple({ sub: "009999.someone-else.0001" });
  const c = deps(seededStorage(), { identities: appleIdentity, apple, fetch: elsewhere.impl });
  const wrong = await deleteAccount({ apple_authorization_code: "code" }, c.d);
  assertEquals([wrong.body.deleted, wrong.body.apple_reason], [true, "different_apple_id"]);
  assertEquals(elsewhere.calls.map((x) => x.url), ["https://appleid.apple.com/auth/token"], "someone else's link isn't revoked");
});

Deno.test("Apple: a storage failure means no revocation and no deletion", async () => {
  const stub = fakeApple();
  const storage = seededStorage();
  storage.fail({ op: "remove", bucket: "avatars", times: Infinity, error: { message: "boom", status: 500 } });
  const { d, deleted } = deps(storage, { identities: appleIdentity, apple, fetch: stub.impl });
  const result = await deleteAccount({ apple_authorization_code: "code" }, d);
  assertEquals(result.status, 503);
  assertEquals(deleted, []);
  assertEquals(stub.calls.map((x) => x.url), ["https://appleid.apple.com/auth/token"]);
});

Deno.test("the .p8 key is read as pasted, with real or literal \\n line breaks", async () => {
  const flat = pem.replace(/\n/g, "\\n");
  assertEquals(pemToDer(flat), pemToDer(pem));
  assertEquals(pemToDer(pem), pkcs8);
  await assertValidClientSecret(await clientSecret({ ...apple, privateKey: flat }));
});
