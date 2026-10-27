// Sign in with Apple token revocation, required by App Store Review
// Guideline 5.1.1(v) when an account that used Sign in with Apple is deleted.
//
// Needs four function secrets that only the Apple Developer account holder
// can create (docs/RELEASE_CHECKLIST.md):
//   APPLE_TEAM_ID, APPLE_KEY_ID, APPLE_PRIVATE_KEY (Sign in with Apple .p8),
//   APPLE_CLIENT_ID (the app's bundle ID, which is the audience of native
//   Sign in with Apple tokens).
// Pull Up keeps no Apple tokens. Before deleting, the app asks the person to
// confirm with Apple, which gives a fresh authorization code (valid for five
// minutes, usable once). The code is exchanged for a refresh token at
// https://appleid.apple.com/auth/token and that token is revoked at
// https://appleid.apple.com/auth/revoke, both authenticated by a client
// secret: an ES256 JWT signed with the .p8 key.

export type RevocationResult =
  | { revoked: true }
  | {
    revoked: false;
    reason: "not_configured" | "no_code" | "exchange_failed" | "different_apple_id" | "revoke_failed";
  };

export interface AppleConfig {
  teamId: string;
  keyId: string;
  /** PEM (PKCS #8) of the Sign in with Apple key. */
  privateKey: string;
  clientId: string;
}

/** A token Apple issued for the code, ready to revoke. */
export interface AppleGrant {
  token: string;
  hint: "refresh_token" | "access_token";
  /** The Apple user (`sub` of the id_token), when Apple returned one. */
  subject: string | null;
}

type Fetch = (input: string | URL | Request, init?: RequestInit) => Promise<Response>;

const TOKEN_URL = "https://appleid.apple.com/auth/token";
const REVOKE_URL = "https://appleid.apple.com/auth/revoke";

/** The secrets, or null when any is missing (revocation is then skipped). */
export function appleConfig(env: (name: string) => string | undefined = (name) => Deno.env.get(name)): AppleConfig | null {
  const teamId = env("APPLE_TEAM_ID");
  const keyId = env("APPLE_KEY_ID");
  const privateKey = env("APPLE_PRIVATE_KEY");
  const clientId = env("APPLE_CLIENT_ID");
  if (!teamId || !keyId || !privateKey || !clientId) return null;
  return { teamId, keyId, privateKey, clientId };
}

function base64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function base64UrlDecode(text: string): Uint8Array {
  const padded = text.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(text.length / 4) * 4, "=");
  return Uint8Array.from(atob(padded), (c) => c.charCodeAt(0));
}

/** DER bytes of a PEM key. Also accepts a key pasted with literal "\n"s. */
export function pemToDer(pem: string): Uint8Array<ArrayBuffer> {
  const body = pem.replace(/\\n/g, "\n").replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  return Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
}

/** The client_secret Apple's token and revoke endpoints expect. */
export async function clientSecret(config: AppleConfig, nowSeconds = Math.floor(Date.now() / 1000)): Promise<string> {
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToDer(config.privateKey),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  const enc = new TextEncoder();
  const header = base64Url(enc.encode(JSON.stringify({ alg: "ES256", kid: config.keyId })));
  const claims = base64Url(enc.encode(JSON.stringify({
    iss: config.teamId,
    iat: nowSeconds,
    exp: nowSeconds + 300,
    aud: "https://appleid.apple.com",
    sub: config.clientId,
  })));
  // WebCrypto's ECDSA signature is r || s, the JWS (ES256) encoding.
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, enc.encode(`${header}.${claims}`));
  return `${header}.${claims}.${base64Url(new Uint8Array(signature))}`;
}

/** `sub` of an id_token Apple just returned over TLS (not re-verified). */
function idTokenSubject(idToken: unknown): string | null {
  if (typeof idToken !== "string") return null;
  try {
    const claims = JSON.parse(new TextDecoder().decode(base64UrlDecode(idToken.split(".")[1] ?? "")));
    return typeof claims.sub === "string" ? claims.sub : null;
  } catch {
    return null;
  }
}

/** Exchanges an authorization code for a token. Codes work once, so no retry. */
export async function exchangeCode(
  config: AppleConfig,
  code: string,
  fetchImpl: Fetch = fetch,
  secret?: string,
): Promise<AppleGrant | null> {
  const response = await fetchImpl(TOKEN_URL, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: config.clientId,
      client_secret: secret ?? await clientSecret(config),
      code,
      grant_type: "authorization_code",
    }),
  }).catch(() => null);
  if (!response?.ok) return null;
  const tokens = await response.json().catch(() => ({})) as { refresh_token?: string; access_token?: string; id_token?: string };
  const token = tokens.refresh_token ?? tokens.access_token;
  if (!token) return null;
  return {
    token,
    hint: tokens.refresh_token ? "refresh_token" : "access_token",
    subject: idTokenSubject(tokens.id_token),
  };
}

/**
 * Revokes the grant. Retries network failures and 5xx/429 with backoff
 * (Apple answers 200 on success); a 4xx is final.
 */
export async function revokeGrant(
  config: AppleConfig,
  grant: AppleGrant,
  fetchImpl: Fetch = fetch,
  options: { attempts?: number; baseDelayMs?: number; sleep?: (ms: number) => Promise<void>; secret?: string } = {},
): Promise<boolean> {
  const attempts = options.attempts ?? 3;
  const sleep = options.sleep ?? ((ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms)));
  const secret = options.secret ?? await clientSecret(config);
  for (let attempt = 1; attempt <= attempts; attempt++) {
    const response = await fetchImpl(REVOKE_URL, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        client_id: config.clientId,
        client_secret: secret,
        token: grant.token,
        token_type_hint: grant.hint,
      }),
    }).catch(() => null);
    if (response?.ok) return true;
    const transient = !response || response.status >= 500 || response.status === 429;
    if (!transient || attempt === attempts) return false;
    await sleep((options.baseDelayMs ?? 500) * 2 ** (attempt - 1));
  }
  return false;
}
