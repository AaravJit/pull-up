// APNs details for send-push, kept apart from the handler so they can be
// unit tested without Apple's servers.

// What to do with a device token after APNs answers.
export type Delivery = "sent" | "drop-token" | "failed";

// Apple's reasons for a token that will never work again: the app was
// deleted (410), the token is malformed or from the other APNs environment,
// or it belongs to a different bundle ID. Anything else (throttling, Apple
// being down, a bad provider token) is our problem or a passing one, so the
// token is kept.
const DEAD_TOKEN_REASONS = new Set(["BadDeviceToken", "DeviceTokenNotForTopic"]);

export function classify(status: number, reason: string | undefined): Delivery {
  if (status >= 200 && status < 300) return "sent";
  if (status === 410) return "drop-token";
  if (status === 400 && reason && DEAD_TOKEN_REASONS.has(reason)) return "drop-token";
  return "failed";
}

export async function responseReason(res: Response): Promise<string | undefined> {
  if (res.ok) return undefined;
  const body = await res.json().catch(() => null) as { reason?: unknown } | null;
  return typeof body?.reason === "string" ? body.reason : undefined;
}

function base64UrlEncode(bytes: Uint8Array): string {
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function signProviderToken(keyId: string, teamId: string, pem: string, issuedAt: number): Promise<string> {
  const der = Uint8Array.from(atob(pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "")), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const enc = new TextEncoder();
  const header = base64UrlEncode(enc.encode(JSON.stringify({ alg: "ES256", kid: keyId })));
  const claims = base64UrlEncode(enc.encode(JSON.stringify({ iss: teamId, iat: issuedAt })));
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, enc.encode(`${header}.${claims}`));
  return `${header}.${claims}.${base64UrlEncode(new Uint8Array(signature))}`;
}

// Apple refuses provider tokens refreshed more often than every 20 minutes
// (429 TooManyProviderTokenUpdates) and older than an hour (403
// ExpiredProviderToken). One token is kept per key while the function's
// worker stays warm and replaced after 40 minutes.
export const PROVIDER_TOKEN_LIFETIME_SECONDS = 40 * 60;

export class ProviderTokens {
  private cached: { key: string; token: string; issuedAt: number } | null = null;

  constructor(private readonly sign = signProviderToken) {}

  async token(keyId: string, teamId: string, pem: string, now = Math.floor(Date.now() / 1000)): Promise<string> {
    const key = `${teamId}/${keyId}`;
    const c = this.cached;
    if (c && c.key === key && now - c.issuedAt < PROVIDER_TOKEN_LIFETIME_SECONDS && now >= c.issuedAt) {
      return c.token;
    }
    const token = await this.sign(keyId, teamId, pem, now);
    this.cached = { key, token, issuedAt: now };
    return token;
  }

  // After APNs says the token is expired or invalid, the next call signs a
  // new one.
  forget() {
    this.cached = null;
  }
}
