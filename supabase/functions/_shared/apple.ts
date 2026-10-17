// Sign in with Apple token revocation, required by App Store Review
// Guideline 5.1.1(v) when an account that used Sign in with Apple is deleted.
//
// Needs four function secrets that only the Apple Developer account holder
// can create (docs/RELEASE_CHECKLIST.md):
//   APPLE_TEAM_ID, APPLE_KEY_ID, APPLE_PRIVATE_KEY (Sign in with Apple .p8),
//   APPLE_CLIENT_ID (the app's bundle ID, which is the audience of native
//   Sign in with Apple tokens).
// The app sends a fresh authorization code from a Sign in with Apple prompt;
// it is exchanged for a refresh token, which is then revoked.

export type RevocationResult =
  | { revoked: true }
  | { revoked: false; reason: "not_configured" | "no_code" | "exchange_failed" | "revoke_failed" };

function base64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function clientSecret(teamId: string, keyId: string, clientId: string, pem: string): Promise<string> {
  const der = Uint8Array.from(atob(pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "")), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const enc = new TextEncoder();
  const now = Math.floor(Date.now() / 1000);
  const header = base64Url(enc.encode(JSON.stringify({ alg: "ES256", kid: keyId })));
  const claims = base64Url(enc.encode(JSON.stringify({
    iss: teamId, iat: now, exp: now + 300, aud: "https://appleid.apple.com", sub: clientId,
  })));
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, enc.encode(`${header}.${claims}`));
  return `${header}.${claims}.${base64Url(new Uint8Array(signature))}`;
}

export async function revokeAppleTokens(authorizationCode: string | undefined): Promise<RevocationResult> {
  const teamId = Deno.env.get("APPLE_TEAM_ID");
  const keyId = Deno.env.get("APPLE_KEY_ID");
  const pem = Deno.env.get("APPLE_PRIVATE_KEY");
  const clientId = Deno.env.get("APPLE_CLIENT_ID");
  if (!teamId || !keyId || !pem || !clientId) return { revoked: false, reason: "not_configured" };
  if (!authorizationCode) return { revoked: false, reason: "no_code" };

  const secret = await clientSecret(teamId, keyId, clientId, pem);
  const tokenResponse = await fetch("https://appleid.apple.com/auth/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: clientId, client_secret: secret, code: authorizationCode, grant_type: "authorization_code",
    }),
  });
  if (!tokenResponse.ok) return { revoked: false, reason: "exchange_failed" };
  const tokens = await tokenResponse.json() as { refresh_token?: string; access_token?: string };
  const token = tokens.refresh_token ?? tokens.access_token;
  if (!token) return { revoked: false, reason: "exchange_failed" };

  const revokeResponse = await fetch("https://appleid.apple.com/auth/revoke", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: clientId, client_secret: secret, token,
      token_type_hint: tokens.refresh_token ? "refresh_token" : "access_token",
    }),
  });
  return revokeResponse.ok ? { revoked: true } : { revoked: false, reason: "revoke_failed" };
}
