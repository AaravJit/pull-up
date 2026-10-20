// deno test supabase/functions/_shared/
// Checks the Apple JWS verifier against a throwaway root -> intermediate ->
// leaf chain generated per run, shaped like Apple's (marker extensions, ES256
// leaf). No network, no real keys.
import "npm:reflect-metadata@0.2.2"; // @peculiar/x509 needs it loaded first
import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { BasicConstraintsExtension, Extension, X509Certificate, X509CertificateGenerator } from "npm:@peculiar/x509@2.1.0";
import { APPLE_ROOT_CA_G3_SHA256, JwsError, verifyAppleJws } from "./jws.ts";

const P384 = { name: "ECDSA", namedCurve: "P-384" };
const P256 = { name: "ECDSA", namedCurve: "P-256" };
const SHA384 = { name: "ECDSA", hash: "SHA-384" };
const DAY = 86_400_000;
const now = Date.now();
const enc = new TextEncoder();

const b64url = (bytes: Uint8Array) => btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const b64 = (cert: X509Certificate) => btoa(String.fromCharCode(...new Uint8Array(cert.rawData)));
const json = (value: unknown) => b64url(enc.encode(JSON.stringify(value)));
const keys = (alg: EcKeyGenParams) => crypto.subtle.generateKey(alg, false, ["sign", "verify"]) as Promise<CryptoKeyPair>;
// Apple's marker extensions carry an ASN.1 NULL.
const marker = (oid: string) => new Extension(oid, false, new Uint8Array([0x05, 0x00]));
const isCa = () => new BasicConstraintsExtension(true, undefined, true);

const rootKeys = await keys(P384);
const intermediateKeys = await keys(P384);
const leafKeys = await keys(P256);

const root = await X509CertificateGenerator.createSelfSigned({
  serialNumber: "01", name: "CN=Test Root CA - G3", keys: rootKeys, signingAlgorithm: SHA384,
  notBefore: new Date(now - 3650 * DAY), notAfter: new Date(now + 3650 * DAY), extensions: [isCa()],
});
const rootFingerprint = Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", root.rawData)),
  (b) => b.toString(16).padStart(2, "0")).join("").toUpperCase();
const trusted = { trustedRoots: [rootFingerprint] };

function issue(subject: string, publicKey: CryptoKey, issuer: X509Certificate, signingKey: CryptoKey,
               extensions: Extension[], validity: { notBefore?: number; notAfter?: number } = {}) {
  return X509CertificateGenerator.create({
    serialNumber: crypto.randomUUID().replace(/-/g, "").slice(0, 16), subject, issuer: issuer.subject,
    publicKey, signingKey, signingAlgorithm: SHA384, extensions,
    notBefore: new Date(validity.notBefore ?? now - 365 * DAY), notAfter: new Date(validity.notAfter ?? now + 365 * DAY),
  });
}

const INTERMEDIATE = "CN=Test Worldwide Developer Relations CA - G6";
const LEAF = "CN=Test Prod ECC Mac App Store and iTunes Store Receipt Signing";
const intermediate = await issue(INTERMEDIATE, intermediateKeys.publicKey, root, rootKeys.privateKey,
  [isCa(), marker("1.2.840.113635.100.6.2.1")]);
const leaf = await issue(LEAF, leafKeys.publicKey, intermediate, intermediateKeys.privateKey, [marker("1.2.840.113635.100.6.11.1")]);

/** Signs `payload` as Apple would, with the given x5c chain and header. */
async function sign(payload: unknown, chain: X509Certificate[] = [leaf, intermediate, root],
                    header: Record<string, unknown> = {}, key = leafKeys.privateKey): Promise<string> {
  const signingInput = `${json({ alg: "ES256", x5c: chain.map(b64), ...header })}.${json(payload)}`;
  const signature = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, enc.encode(signingInput)));
  return `${signingInput}.${b64url(signature)}`;
}

const notification = { notificationType: "DID_RENEW", notificationUUID: crypto.randomUUID(), signedDate: now };

async function rejects(promise: Promise<unknown>, code: JwsError["code"]) {
  const error = await assertRejects(() => promise, JwsError);
  assertEquals(error.code, code);
}

Deno.test("the default trusted root is Apple Root CA - G3", () => {
  assertEquals(APPLE_ROOT_CA_G3_SHA256, "63343ABFB89A6A03EBB57E9B3F5FA7BE7C4F5C756F3017B3A8C488C3653E9179");
});

Deno.test("a JWS signed through a trusted chain is accepted", async () => {
  assertEquals(await verifyAppleJws(await sign(notification), trusted), notification);
  const lower = { trustedRoots: [rootFingerprint.toLowerCase()] };
  assertEquals(await verifyAppleJws(await sign(notification), lower), notification, "fingerprint case doesn't matter");
});

Deno.test("a chain that doesn't end at a trusted root is refused", async () => {
  await rejects(verifyAppleJws(await sign(notification)), "untrusted_root"); // default: Apple's root only
  await rejects(verifyAppleJws(await sign(notification), { trustedRoots: [APPLE_ROOT_CA_G3_SHA256] }), "untrusted_root");
});

Deno.test("a tampered payload is refused", async () => {
  const [header, , signature] = (await sign(notification)).split(".");
  const forged = `${header}.${json({ ...notification, notificationType: "REFUND_REVERSED" })}.${signature}`;
  await rejects(verifyAppleJws(forged, trusted), "bad_signature");
});

Deno.test("a tampered or truncated signature is refused", async () => {
  const [header, payload, signature] = (await sign(notification)).split(".");
  const bytes = Uint8Array.from(atob(signature.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - signature.length % 4) % 4)),
    (c) => c.charCodeAt(0));
  bytes[10] ^= 0x01;
  await rejects(verifyAppleJws(`${header}.${payload}.${b64url(bytes)}`, trusted), "bad_signature");
  await rejects(verifyAppleJws(`${header}.${payload}.${b64url(bytes.slice(0, 63))}`, trusted), "bad_signature");
  await rejects(verifyAppleJws(`${header}.${payload}.`, trusted), "bad_signature");
});

Deno.test("a JWS signed by a key other than the leaf's is refused", async () => {
  const stranger = await keys(P256);
  await rejects(verifyAppleJws(await sign(notification, undefined, {}, stranger.privateKey), trusted), "bad_signature");
});

Deno.test("only ES256 is accepted", async () => {
  for (const alg of ["RS256", "ES384", "none", undefined]) {
    await rejects(verifyAppleJws(await sign(notification, undefined, { alg }), trusted), "malformed");
  }
});

Deno.test("a leaf without Apple's receipt-signing marker is refused", async () => {
  const bare = await issue(LEAF, leafKeys.publicKey, intermediate, intermediateKeys.privateKey, []);
  await rejects(verifyAppleJws(await sign(notification, [bare, intermediate, root]), trusted), "bad_chain");
});

Deno.test("an intermediate without Apple's WWDR marker is refused", async () => {
  const bare = await issue(INTERMEDIATE, intermediateKeys.publicKey, root, rootKeys.privateKey, [isCa()]);
  const leafUnderBare = await issue(LEAF, leafKeys.publicKey, bare, intermediateKeys.privateKey, [marker("1.2.840.113635.100.6.11.1")]);
  await rejects(verifyAppleJws(await sign(notification, [leafUnderBare, bare, root]), trusted), "bad_chain");
});

Deno.test("an intermediate that isn't a CA is refused", async () => {
  const notCa = await issue(INTERMEDIATE, intermediateKeys.publicKey, root, rootKeys.privateKey, [marker("1.2.840.113635.100.6.2.1")]);
  await rejects(verifyAppleJws(await sign(notification, [leaf, notCa, root]), trusted), "bad_chain");
});

Deno.test("a leaf signed by a different intermediate is refused", async () => {
  // Same name as the real intermediate, different key: only the signature tells them apart.
  const otherKeys = await keys(P384);
  const other = await issue(INTERMEDIATE, otherKeys.publicKey, root, rootKeys.privateKey, [isCa(), marker("1.2.840.113635.100.6.2.1")]);
  const otherLeaf = await issue(LEAF, leafKeys.publicKey, other, otherKeys.privateKey, [marker("1.2.840.113635.100.6.11.1")]);
  await rejects(verifyAppleJws(await sign(notification, [otherLeaf, intermediate, root]), trusted), "bad_chain");
  // And an intermediate the root didn't sign.
  const selfSigned = await issue(INTERMEDIATE, otherKeys.publicKey, root, otherKeys.privateKey, [isCa(), marker("1.2.840.113635.100.6.2.1")]);
  await rejects(verifyAppleJws(await sign(notification, [otherLeaf, selfSigned, root]), trusted), "bad_chain");
});

Deno.test("certificates must be valid at the payload's signedDate", async () => {
  const expired = await issue(LEAF, leafKeys.publicKey, intermediate, intermediateKeys.privateKey,
    [marker("1.2.840.113635.100.6.11.1")], { notBefore: now - 30 * DAY, notAfter: now - DAY });
  await rejects(verifyAppleJws(await sign(notification, [expired, intermediate, root]), trusted), "expired");
  // The same leaf is fine for something Apple signed while it was valid.
  const old = { ...notification, signedDate: now - 2 * DAY };
  assertEquals(await verifyAppleJws(await sign(old, [expired, intermediate, root]), trusted), old);
  // Nothing in the chain is valid before the root was issued.
  await rejects(verifyAppleJws(await sign({ ...notification, signedDate: now - 4000 * DAY }), trusted), "expired");
  await rejects(verifyAppleJws(await sign({ notificationType: "TEST" }), trusted), "malformed"); // no signedDate
});

Deno.test("x5c must be exactly leaf, intermediate, root", async () => {
  await rejects(verifyAppleJws(await sign(notification, [leaf, root]), trusted), "malformed");
  await rejects(verifyAppleJws(await sign(notification, [leaf, intermediate, intermediate, root]), trusted), "malformed");
  await rejects(verifyAppleJws(await sign(notification, [], { x5c: undefined }), trusted), "malformed");
  await rejects(verifyAppleJws(await sign(notification, [], { x5c: ["bm90IGEgY2VydA==", "!!", "x"] }), trusted), "malformed");
});

Deno.test("things that aren't JWS are refused as malformed", async () => {
  for (const garbage of ["", "not-a-jws", "a.b.c", "a.b.c.d", `${b64url(enc.encode("not json"))}.e30.c2ln`, `${json(null)}.e30.c2ln`]) {
    await rejects(verifyAppleJws(garbage, trusted), "malformed");
  }
  await rejects(verifyAppleJws(undefined as unknown as string, trusted), "malformed");
  // A correctly signed payload that isn't JSON.
  const [header] = (await sign(notification)).split(".");
  const payload = b64url(enc.encode("not json"));
  const signature = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, leafKeys.privateKey,
    enc.encode(`${header}.${payload}`)));
  await rejects(verifyAppleJws(`${header}.${payload}.${b64url(signature)}`, trusted), "malformed");
});
