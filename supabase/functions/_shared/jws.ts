// Verifies JWS that Apple signs (App Store Server Notifications V2 and the
// signedTransactionInfo / signedRenewalInfo inside them), the way Apple's own
// SignedDataVerifier does with online (OCSP) checks off:
//
//   1. The header is ES256 and carries x5c = [leaf, intermediate, root].
//   2. The root is Apple Root CA - G3, pinned by SHA-256 fingerprint.
//   3. root signs intermediate, intermediate signs leaf, and both carry
//      Apple's marker extensions (intermediate 1.2.840.113635.100.6.2.1,
//      leaf 1.2.840.113635.100.6.11.1).
//   4. The leaf's P-256 key signs `header.payload`.
//   5. All three certificates are valid at the payload's signedDate. That date
//      is read only after step 4, so it is Apple's word, not the sender's.
//
// Anything else throws JwsError and nothing in the payload is returned.
// Certificates are parsed with @peculiar/x509 (WebCrypto only), which needs a
// Reflect polyfill imported before it.
import "npm:reflect-metadata@0.2.2";
import { BasicConstraintsExtension, X509Certificate } from "npm:@peculiar/x509@2.1.0";

/** SHA-256 of Apple Root CA - G3's DER (https://www.apple.com/certificateauthority/). */
export const APPLE_ROOT_CA_G3_SHA256 = "63343ABFB89A6A03EBB57E9B3F5FA7BE7C4F5C756F3017B3A8C488C3653E9179";

const INTERMEDIATE_OID = "1.2.840.113635.100.6.2.1"; // Apple WWDR intermediate marker
const LEAF_OID = "1.2.840.113635.100.6.11.1"; // App Store receipt signing marker

export class JwsError extends Error {
  constructor(readonly code: "malformed" | "untrusted_root" | "bad_chain" | "bad_signature" | "expired", message?: string) {
    super(message ?? code);
  }
}

export interface VerifyOptions {
  /** Upper-case hex SHA-256 fingerprints of acceptable roots. Tests pass their own. */
  trustedRoots?: readonly string[];
}

function base64UrlDecode(text: string): Uint8Array<ArrayBuffer> {
  const padded = text.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(text.length / 4) * 4, "=");
  return Uint8Array.from(atob(padded), (c) => c.charCodeAt(0));
}

const hex = (buffer: ArrayBuffer) => Array.from(new Uint8Array(buffer), (b) => b.toString(16).padStart(2, "0")).join("").toUpperCase();

function decodeJson<T>(part: string, what: string): T {
  try {
    return JSON.parse(new TextDecoder().decode(base64UrlDecode(part))) as T;
  } catch {
    throw new JwsError("malformed", `unreadable JWS ${what}`);
  }
}

// `issuer` signed `cert`, and the names chain up.
async function signedBy(cert: X509Certificate, issuer: X509Certificate): Promise<boolean> {
  try {
    return cert.issuer === issuer.subject && await cert.verify({ publicKey: issuer, signatureOnly: true });
  } catch {
    return false;
  }
}

const validAt = (cert: X509Certificate, time: number) => cert.notBefore.getTime() <= time && time <= cert.notAfter.getTime();

/** Returns the payload of an Apple-signed JWS, or throws JwsError. */
export async function verifyAppleJws<T>(jws: string, options: VerifyOptions = {}): Promise<T> {
  const trustedRoots = options.trustedRoots ?? [APPLE_ROOT_CA_G3_SHA256];
  const parts = typeof jws === "string" ? jws.split(".") : [];
  if (parts.length !== 3) throw new JwsError("malformed", "not a JWS");
  const [headerPart, payloadPart, signaturePart] = parts;

  const header = decodeJson<{ alg?: unknown; x5c?: unknown }>(headerPart, "header");
  if (header?.alg !== "ES256") throw new JwsError("malformed", "alg is not ES256");
  const x5c = header.x5c;
  if (!Array.isArray(x5c) || x5c.length !== 3 || !x5c.every((c) => typeof c === "string")) {
    throw new JwsError("malformed", "x5c is not [leaf, intermediate, root]");
  }
  let leaf: X509Certificate, intermediate: X509Certificate, root: X509Certificate;
  try {
    [leaf, intermediate, root] = x5c.map((c: string) => new X509Certificate(Uint8Array.from(atob(c), (ch) => ch.charCodeAt(0))));
  } catch {
    throw new JwsError("malformed", "unreadable certificate");
  }

  // The chain: pinned root -> Apple intermediate (a CA) -> Apple leaf.
  const fingerprint = hex(await crypto.subtle.digest("SHA-256", root.rawData));
  if (!trustedRoots.some((trusted) => trusted.toUpperCase() === fingerprint)) {
    throw new JwsError("untrusted_root");
  }
  if (!(await signedBy(intermediate, root)) || !(await signedBy(leaf, intermediate))) {
    throw new JwsError("bad_chain", "certificate signatures don't chain to the root");
  }
  if (!intermediate.getExtension(BasicConstraintsExtension)?.ca) throw new JwsError("bad_chain", "intermediate is not a CA");
  if (!intermediate.getExtension(INTERMEDIATE_OID) || !leaf.getExtension(LEAF_OID)) {
    throw new JwsError("bad_chain", "missing Apple marker extension");
  }

  // The JWS itself: ES256 is the raw 64-byte r||s (RFC 7515), which is also
  // WebCrypto's ECDSA format.
  let ok = false;
  try {
    const signature = base64UrlDecode(signaturePart);
    if (signature.length === 64) {
      const key = await leaf.publicKey.export({ name: "ECDSA", namedCurve: "P-256" }, ["verify"]);
      ok = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, signature,
        new TextEncoder().encode(`${headerPart}.${payloadPart}`));
    }
  } catch {
    ok = false;
  }
  if (!ok) throw new JwsError("bad_signature");

  // Now signed by Apple, so signedDate can stand in for "now".
  const payload = decodeJson<T & { signedDate?: unknown }>(payloadPart, "payload");
  const signedDate = payload?.signedDate;
  if (typeof signedDate !== "number" || !Number.isFinite(signedDate)) throw new JwsError("malformed", "no signedDate");
  if (![leaf, intermediate, root].every((cert) => validAt(cert, signedDate))) {
    throw new JwsError("expired", "a certificate was not valid at signedDate");
  }
  return payload;
}
