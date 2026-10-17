// App Store Server API client for Pull Up Pro.
//
// Nothing the phone sends is trusted. The app (or an App Store Server
// Notification) only tells us *which* transaction to look at; the state we
// record comes from Apple's App Store Server API over TLS, authenticated with
// an In-App Purchase key. That avoids hand-verifying JWS certificate chains,
// and means a forged or replayed transaction can't grant anything Apple
// doesn't confirm.
//
// Needs four function secrets that only the App Store Connect account holder
// can create (docs/RELEASE_CHECKLIST.md):
//   APPSTORE_ISSUER_ID, APPSTORE_KEY_ID, APPSTORE_PRIVATE_KEY (In-App
//   Purchase key, .p8), APPSTORE_BUNDLE_ID.
// Without them the functions answer 503 "not_configured" and nobody is
// granted Pro.

export const PRODUCT_IDS = ["app.pullup.pro.monthly", "app.pullup.pro.yearly"] as const;

const HOSTS = {
  Production: "https://api.storekit.itunes.apple.com",
  Sandbox: "https://api.storekit-sandbox.itunes.apple.com",
} as const;

export type Environment = keyof typeof HOSTS;

export interface AppStoreConfig {
  issuerId: string;
  keyId: string;
  privateKey: string;
  bundleId: string;
}

export function loadConfig(env: (name: string) => string | undefined = (n) => Deno.env.get(n)): AppStoreConfig | null {
  const issuerId = env("APPSTORE_ISSUER_ID");
  const keyId = env("APPSTORE_KEY_ID");
  const privateKey = env("APPSTORE_PRIVATE_KEY");
  const bundleId = env("APPSTORE_BUNDLE_ID");
  if (!issuerId || !keyId || !privateKey || !bundleId) return null;
  return { issuerId, keyId, privateKey, bundleId };
}

/** Fields of Apple's JWSTransactionDecodedPayload that Pull Up uses. */
export interface TransactionInfo {
  transactionId?: string;
  originalTransactionId?: string;
  bundleId?: string;
  productId?: string;
  expiresDate?: number;
  revocationDate?: number;
  appAccountToken?: string;
  environment?: string;
  signedDate?: number;
}

/** Fields of Apple's JWSRenewalInfoDecodedPayload that Pull Up uses. */
export interface RenewalInfo {
  autoRenewStatus?: number;
  gracePeriodExpiresDate?: number;
  signedDate?: number;
}

export type EntitlementStatus = "active" | "grace_period" | "billing_retry" | "expired" | "revoked";

/** One subscription as Apple reports it, ready for public.apply_entitlement. */
export interface AppleSubscription {
  environment: Environment;
  originalTransactionId: string;
  productId: string;
  appAccountToken: string | null;
  status: EntitlementStatus;
  expiresAt: string | null;
  graceExpiresAt: string | null;
  autoRenew: boolean;
  signedAt: string;
}

export class AppStoreError extends Error {
  constructor(readonly code: "not_found" | "unauthorized" | "apple_unavailable" | "wrong_app" | "unknown_product" | "malformed",
              message?: string) {
    super(message ?? code);
  }
}

function base64UrlEncode(bytes: Uint8Array): string {
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function base64UrlDecode(text: string): Uint8Array {
  const padded = text.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(text.length / 4) * 4, "=");
  return Uint8Array.from(atob(padded), (c) => c.charCodeAt(0));
}

/**
 * Reads a JWS payload WITHOUT checking its signature. Only for picking which
 * transaction to ask Apple about, and for reading data Apple just returned
 * to us over TLS.
 */
export function readJwsPayload<T>(jws: string): T {
  const parts = jws.split(".");
  if (parts.length !== 3) throw new AppStoreError("malformed", "not a JWS");
  try {
    return JSON.parse(new TextDecoder().decode(base64UrlDecode(parts[1]))) as T;
  } catch {
    throw new AppStoreError("malformed", "unreadable JWS payload");
  }
}

/** ES256 bearer token for the App Store Server API (valid 5 minutes). */
export async function apiToken(config: AppStoreConfig, now = Date.now()): Promise<string> {
  const pem = config.privateKey.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const enc = new TextEncoder();
  const iat = Math.floor(now / 1000);
  const header = base64UrlEncode(enc.encode(JSON.stringify({ alg: "ES256", kid: config.keyId, typ: "JWT" })));
  const claims = base64UrlEncode(enc.encode(JSON.stringify({
    iss: config.issuerId, iat, exp: iat + 300, aud: "appstoreconnect-v1", bid: config.bundleId,
  })));
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, enc.encode(`${header}.${claims}`));
  return `${header}.${claims}.${base64UrlEncode(new Uint8Array(signature))}`;
}

const STATUS: Record<number, EntitlementStatus> = {
  1: "active",
  2: "expired",
  3: "billing_retry",
  4: "grace_period",
  5: "revoked",
};

const iso = (ms: number | undefined): string | null => (typeof ms === "number" ? new Date(ms).toISOString() : null);

interface StatusResponse {
  environment?: string;
  bundleId?: string;
  data?: { lastTransactions?: { status?: number; originalTransactionId?: string; signedTransactionInfo?: string; signedRenewalInfo?: string }[] }[];
}

/**
 * Asks Apple for the current state of the subscription that `transactionId`
 * belongs to. Tries production first and falls back to sandbox, as Apple
 * recommends (App Review purchases with sandbox accounts on release builds).
 */
export async function fetchSubscription(
  config: AppStoreConfig, transactionId: string, fetchImpl: typeof fetch = fetch, originalTransactionId?: string,
): Promise<AppleSubscription> {
  if (!/^[0-9]{1,32}$/.test(transactionId)) throw new AppStoreError("malformed", "bad transaction id");
  const token = await apiToken(config);
  for (const environment of ["Production", "Sandbox"] as const) {
    const response = await fetchImpl(`${HOSTS[environment]}/inApps/v1/subscriptions/${transactionId}`, {
      headers: { authorization: `Bearer ${token}` },
    });
    if (response.status === 404) continue;
    if (response.status === 401) throw new AppStoreError("unauthorized", "App Store Server API rejected the key");
    if (!response.ok) throw new AppStoreError("apple_unavailable", `App Store Server API answered ${response.status}`);
    const body = await response.json() as StatusResponse;
    if (body.bundleId !== config.bundleId) throw new AppStoreError("wrong_app");
    return pickSubscription(body, environment, originalTransactionId ?? transactionId, transactionId);
  }
  throw new AppStoreError("not_found", "Apple has no subscription for this transaction");
}

// Apple answers with every subscription this Apple account has in the app;
// prefer the one we were asked about.
function pickSubscription(body: StatusResponse, environment: Environment, original: string, transactionId: string): AppleSubscription {
  const items = (body.data ?? []).flatMap((group) => group.lastTransactions ?? []);
  const decoded = items.map((item) => ({
    item,
    transaction: item.signedTransactionInfo ? readJwsPayload<TransactionInfo>(item.signedTransactionInfo) : {},
    renewal: item.signedRenewalInfo ? readJwsPayload<RenewalInfo>(item.signedRenewalInfo) : {},
  }));
  const match = decoded.find(({ item, transaction }) =>
    (item.originalTransactionId ?? transaction.originalTransactionId) === original || transaction.transactionId === transactionId
  ) ?? decoded.find(({ transaction }) => (PRODUCT_IDS as readonly string[]).includes(transaction.productId ?? ""));
  if (!match) throw new AppStoreError("not_found", "no Pull Up Pro subscription in Apple's answer");
  const { item, transaction, renewal } = match;
  if (!(PRODUCT_IDS as readonly string[]).includes(transaction.productId ?? "")) {
    throw new AppStoreError("unknown_product", `unexpected product ${transaction.productId}`);
  }
  const originalTransactionId = item.originalTransactionId ?? transaction.originalTransactionId;
  if (!originalTransactionId) throw new AppStoreError("malformed", "no original transaction id");
  const status = (transaction.revocationDate ? "revoked" : STATUS[item.status ?? 0]) ?? "expired";
  const signed = Math.max(transaction.signedDate ?? 0, renewal.signedDate ?? 0) || Date.now();
  return {
    environment,
    originalTransactionId,
    productId: transaction.productId!,
    appAccountToken: transaction.appAccountToken?.toLowerCase() ?? null,
    status,
    expiresAt: iso(transaction.expiresDate),
    graceExpiresAt: iso(renewal.gracePeriodExpiresDate),
    autoRenew: renewal.autoRenewStatus === 1,
    signedAt: new Date(signed).toISOString(),
  };
}

/** Arguments for public.apply_entitlement. */
export function applyArguments(user: string, subscription: AppleSubscription) {
  return {
    p_user: user,
    p_original_transaction_id: subscription.originalTransactionId,
    p_product_id: subscription.productId,
    p_status: subscription.status,
    p_expires_at: subscription.expiresAt,
    p_grace_expires_at: subscription.graceExpiresAt,
    p_auto_renew: subscription.autoRenew,
    p_environment: subscription.environment,
    p_signed_at: subscription.signedAt,
  };
}
