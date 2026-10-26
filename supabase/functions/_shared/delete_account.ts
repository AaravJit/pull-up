// What delete-account does, with its Supabase and Apple calls passed in so
// it can be tested without a project (delete_account_test.ts).
//
// Order, and why:
//   1. Who is calling, from their own JWT (never a user id in the body).
//   2. Sign in with Apple accounts: exchange the app's one-time authorization
//      code now, while it's fresh (it expires after five minutes).
//   3. Storage. Files don't cascade from the database and are found by
//      folder: "<uid>/..." in avatars, vehicle-media and post-media, and
//      "<conversation>/..." in dm-media for each of the person's
//      conversations. All of that must go while the account exists, because
//      the conversations (the only way to find DM folders) and the account
//      (the only thing a retry can authenticate as) are deleted with it.
//      Any failure stops here with a 503: nothing else is deleted, the app
//      shows the message, and calling again finishes the job.
//   4. The auth user. Every table cascades from it (pgTAP 018). A failure
//      is a 500 and, again, calling again finishes the job.
//   5. Apple revocation, after the account is gone, so a failed deletion
//      never leaves a live account whose Apple link was cut. Revocation
//      failing doesn't undo the deletion; the response says so and the app
//      tells the person how to remove Pull Up from their Apple Account.
//
// A call whose JWT is valid but whose user no longer exists (a retry after
// the first response was lost) answers that the account is deleted.
import {
  type AppleConfig,
  type AppleGrant,
  clientSecret,
  exchangeCode,
  type RevocationResult,
  revokeGrant,
} from "./apple.ts";
import { type CleanupOptions, removeTree, type StorageClient } from "./storage_cleanup.ts";

/** Buckets whose objects live under "<uid>/...". */
export const USER_BUCKETS = ["avatars", "vehicle-media", "post-media"] as const;
/** Message photos live under "<conversation>/<sender>/...". */
export const DM_BUCKET = "dm-media";

export interface Identity {
  provider: string;
  id?: string;
  identity_data?: Record<string, unknown> | null;
}

export interface DeleteAccountDeps {
  /** The caller, resolved from their JWT by Supabase Auth. */
  user(): Promise<{
    user: { id: string; identities?: Identity[] | null } | null;
    error: { message: string; code?: string; status?: number } | null;
  }>;
  /** Ids of every conversation the user is in (all pages). */
  conversationIds(uid: string): Promise<{ ids: string[]; error: string | null }>;
  storage: StorageClient;
  deleteUser(uid: string): Promise<{ error: { message: string } | null }>;
  /** null when the APPLE_* secrets aren't set. */
  apple: AppleConfig | null;
  fetch?: (input: string | URL | Request, init?: RequestInit) => Promise<Response>;
  cleanup?: CleanupOptions;
  appleRetry?: { attempts?: number; baseDelayMs?: number; sleep?: (ms: number) => Promise<void> };
  /** Never given secrets, codes or tokens. */
  log?: (line: string) => void;
}

export interface DeleteAccountResponse {
  status: number;
  body: Record<string, unknown>;
}

const RETRY_MESSAGE = "Your account wasn't deleted yet: some of your files couldn't be removed. Nothing else was changed. Try again in a minute.";

function appleSubject(identities: Identity[]): string | null {
  const apple = identities.find((identity) => identity.provider === "apple");
  const sub = apple?.identity_data?.["sub"];
  return typeof sub === "string" ? sub : apple?.id ?? null;
}

export async function deleteAccount(body: unknown, deps: DeleteAccountDeps): Promise<DeleteAccountResponse> {
  const log = deps.log ?? ((line: string) => console.log(line));

  const { user, error: userError } = await deps.user();
  if (userError?.code === "user_not_found") {
    // The JWT checked out but its user is gone: an earlier call finished.
    return { status: 200, body: { deleted: true, already_deleted: true, apple_revoked: null, apple_reason: null } };
  }
  if (userError || !user) {
    return { status: 401, body: { error: "invalid session", message: "Your session has ended. Sign in again, then delete your account." } };
  }
  const uid = user.id;
  const identities = user.identities ?? [];
  const usesApple = identities.some((identity) => identity.provider === "apple");

  // 2. Exchange the Apple code while it's valid.
  let apple: RevocationResult | null = null;
  let grant: AppleGrant | null = null;
  if (usesApple) {
    const code = (body as { apple_authorization_code?: unknown } | null)?.apple_authorization_code;
    if (!deps.apple) {
      apple = { revoked: false, reason: "not_configured" };
      log("delete-account: Sign in with Apple revocation skipped, APPLE_* secrets are not configured");
    } else if (typeof code !== "string" || code.length === 0) {
      apple = { revoked: false, reason: "no_code" };
    } else {
      try {
        grant = await exchangeCode(deps.apple, code, deps.fetch, await clientSecret(deps.apple));
      } catch {
        grant = null; // unreadable key: reported as exchange_failed
      }
      if (!grant) {
        apple = { revoked: false, reason: "exchange_failed" };
      } else if (grant.subject && appleSubject(identities) && grant.subject !== appleSubject(identities)) {
        // The code came from a different Apple Account than this Pull Up
        // account signs in with. Revoking it would cut someone else's link.
        apple = { revoked: false, reason: "different_apple_id" };
        grant = null;
      }
    }
  }

  // 3. Storage, while the account and its conversations still exist.
  const { ids: conversations, error: conversationError } = await deps.conversationIds(uid);
  if (conversationError) {
    log(`delete-account: listing conversations failed: ${conversationError}`);
    return { status: 503, body: { error: "storage_incomplete", message: RETRY_MESSAGE, deleted: false } };
  }
  const folders: [string, string][] = [
    ...conversations.map((id): [string, string] => [DM_BUCKET, id]),
    ...USER_BUCKETS.map((bucket): [string, string] => [bucket, uid]),
  ];
  let removedFiles = 0;
  for (const [bucket, root] of folders) {
    const result = await removeTree(deps.storage, bucket, root, deps.cleanup);
    removedFiles += result.removed;
    if (!result.ok) {
      log(`delete-account: storage cleanup stopped after ${removedFiles} files: ${result.error}`);
      return {
        status: 503,
        body: { error: "storage_incomplete", message: RETRY_MESSAGE, deleted: false, removed_files: removedFiles },
      };
    }
  }

  // 4. The account; every table cascades from it.
  const { error: deleteError } = await deps.deleteUser(uid);
  if (deleteError) {
    log(`delete-account: deleting the auth user failed: ${deleteError.message}`);
    return {
      status: 500,
      body: {
        error: "delete_failed",
        message: "Your files were removed, but your account couldn't be deleted. Try again in a minute.",
        deleted: false,
        removed_files: removedFiles,
      },
    };
  }

  // 5. Apple, now that nothing can be left half-deleted.
  if (grant && deps.apple) {
    // A fresh client secret: storage may have taken longer than the last one lives.
    const revoked = await revokeGrant(deps.apple, grant, deps.fetch, deps.appleRetry).catch(() => false);
    apple = revoked ? { revoked: true } : { revoked: false, reason: "revoke_failed" };
  }
  if (apple && !apple.revoked) log(`delete-account: Sign in with Apple not revoked (${apple.reason})`);
  log(`delete-account: deleted an account and ${removedFiles} files`);

  return {
    status: 200,
    body: {
      deleted: true,
      removed_files: removedFiles,
      apple_revoked: apple ? apple.revoked : null,
      apple_reason: apple && !apple.revoked ? apple.reason : null,
    },
  };
}
