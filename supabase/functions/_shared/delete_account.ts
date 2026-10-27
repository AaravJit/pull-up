// What delete-account does, with its Supabase and Apple calls passed in so
// it can be tested without a project (delete_account_test.ts).
//
// Order, and why:
//   1. Who is calling, from their own JWT (never a user id in the body).
//   2. A deletion job is recorded (private.account_deletions, migration
//      20261025000110) before anything is removed. From then on the account
//      can't upload, and the deletion is finished even if the person never
//      opens the app again: the scheduled run (finishPendingDeletions)
//      retries unfinished jobs with the service role.
//   3. Sign in with Apple accounts: the app's one-time authorization code is
//      exchanged now, while it's fresh (it expires after five minutes).
//   4. Storage. Files don't cascade from the database and are found by
//      folder: "<uid>/..." in avatars, vehicle-media and post-media, and
//      "<conversation>/..." in dm-media for each of the person's
//      conversations. All of it must go while the account exists, because
//      the conversations (the only way to find DM folders), the job row and
//      the auth user are deleted together. A failure stops here: the job
//      keeps the error and any Apple token still to revoke, and the app
//      shows a message. Calling again, or the scheduled run, finishes it.
//   5. The auth user, last. Every table cascades from it (pgTAP 018),
//      including the job row.
//   6. Apple revocation, after the account is gone, so a failed deletion
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

/** The durable record of a deletion in progress. */
export interface DeletionJobs {
  /** Records an attempt; returns an Apple token kept from an earlier one. */
  begin(uid: string): Promise<{ apple: AppleGrant | null; error: string | null }>;
  /** Keeps why the attempt stopped, and a token to revoke later (null keeps the stored one). */
  failed(uid: string, error: string, apple: AppleGrant | null): Promise<void>;
  /** Accounts whose deletion started but didn't finish, due for a retry. */
  due(limit: number): Promise<{ ids: string[]; error: string | null }>;
}

export interface DeleteAccountDeps {
  /** The caller, resolved from their JWT by Supabase Auth. */
  user(): Promise<{
    user: { id: string; identities?: Identity[] | null } | null;
    error: { message: string; code?: string; status?: number } | null;
  }>;
  jobs: DeletionJobs;
  /** Ids of every conversation the user is in (all pages). */
  conversationIds(uid: string): Promise<{ ids: string[]; error: string | null }>;
  storage: StorageClient;
  /** A user that's already gone counts as deleted. */
  deleteUser(uid: string): Promise<{ error: { message: string; status?: number } | null }>;
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

const UNFINISHED_MESSAGE =
  "Your account is being deleted, but some of your files couldn't be removed yet. Pull Up keeps retrying on its own; you can also try again in a minute.";

function appleSubject(identities: Identity[]): string | null {
  const apple = identities.find((identity) => identity.provider === "apple");
  const sub = apple?.identity_data?.["sub"];
  return typeof sub === "string" ? sub : apple?.id ?? null;
}

type Finished =
  | { ok: true; removed: number; apple: RevocationResult | null }
  | { ok: false; removed: number; stage: "storage" | "auth"; error: string };

/** Steps 4–6 for one account, shared by the person's call and the scheduled run. */
async function finish(uid: string, grant: AppleGrant | null, deps: DeleteAccountDeps): Promise<Finished> {
  const { ids: conversations, error: conversationError } = await deps.conversationIds(uid);
  if (conversationError) return { ok: false, removed: 0, stage: "storage", error: `listing conversations: ${conversationError}` };
  const folders: [string, string][] = [
    ...conversations.map((id): [string, string] => [DM_BUCKET, id]),
    ...USER_BUCKETS.map((bucket): [string, string] => [bucket, uid]),
  ];
  let removed = 0;
  for (const [bucket, root] of folders) {
    const result = await removeTree(deps.storage, bucket, root, deps.cleanup);
    removed += result.removed;
    if (!result.ok) return { ok: false, removed, stage: "storage", error: result.error };
  }

  const { error: deleteError } = await deps.deleteUser(uid);
  if (deleteError && deleteError.status !== 404) return { ok: false, removed, stage: "auth", error: deleteError.message };

  let apple: RevocationResult | null = null;
  if (grant && deps.apple) {
    // A fresh client secret: storage may have taken longer than one lives.
    const revoked = await revokeGrant(deps.apple, grant, deps.fetch, deps.appleRetry).catch(() => false);
    apple = revoked ? { revoked: true } : { revoked: false, reason: "revoke_failed" };
  } else if (grant) {
    apple = { revoked: false, reason: "not_configured" };
  }
  return { ok: true, removed, apple };
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

  // 2. The job, before anything is removed.
  const job = await deps.jobs.begin(uid);
  if (job.error) {
    log(`delete-account: couldn't record the deletion: ${job.error}`);
    return {
      status: 503,
      body: { error: "not_started", message: "Pull Up couldn't start deleting your account. Nothing was changed. Try again in a minute.", deleted: false },
    };
  }

  // 3. Exchange the Apple code while it's valid.
  let apple: RevocationResult | null = null;
  let fresh: AppleGrant | null = null;
  if (usesApple) {
    const code = (body as { apple_authorization_code?: unknown } | null)?.apple_authorization_code;
    if (!deps.apple) {
      apple = { revoked: false, reason: "not_configured" };
      log("delete-account: Sign in with Apple revocation skipped, APPLE_* secrets are not configured");
    } else if (typeof code === "string" && code.length > 0) {
      try {
        fresh = await exchangeCode(deps.apple, code, deps.fetch, await clientSecret(deps.apple));
      } catch {
        fresh = null; // unreadable key: reported as exchange_failed
      }
      if (!fresh) {
        apple = { revoked: false, reason: "exchange_failed" };
      } else if (fresh.subject && appleSubject(identities) && fresh.subject !== appleSubject(identities)) {
        // The code came from a different Apple Account than this Pull Up
        // account signs in with. Revoking it would cut someone else's link.
        apple = { revoked: false, reason: "different_apple_id" };
        fresh = null;
      }
    } else if (!job.apple) {
      apple = { revoked: false, reason: "no_code" };
    }
  }
  const grant = fresh ?? (usesApple && deps.apple ? job.apple : null);

  // 4–6.
  const done = await finish(uid, grant, deps);
  if (!done.ok) {
    await deps.jobs.failed(uid, `${done.stage}: ${done.error}`, fresh).catch(() => {});
    log(`delete-account: stopped at ${done.stage} after ${done.removed} files: ${done.error}`);
    return {
      status: done.stage === "storage" ? 503 : 500,
      body: { error: done.stage === "storage" ? "storage_incomplete" : "delete_failed", message: UNFINISHED_MESSAGE, deleted: false, removed_files: done.removed },
    };
  }
  if (done.apple) apple = done.apple;
  if (apple && !apple.revoked) log(`delete-account: Sign in with Apple not revoked (${apple.reason})`);
  log(`delete-account: deleted an account and ${done.removed} files`);
  return {
    status: 200,
    body: {
      deleted: true,
      removed_files: done.removed,
      apple_revoked: apple ? apple.revoked : null,
      apple_reason: apple && !apple.revoked ? apple.reason : null,
    },
  };
}

/** The scheduled run: finishes deletions that started but stopped. */
export async function finishPendingDeletions(
  deps: Omit<DeleteAccountDeps, "user">,
  limit = 20,
): Promise<DeleteAccountResponse> {
  const log = deps.log ?? ((line: string) => console.log(line));
  const { ids, error } = await deps.jobs.due(limit);
  if (error) return { status: 500, body: { error: `listing unfinished deletions: ${error}` } };
  let finished = 0;
  let failed = 0;
  let appleNotRevoked = 0;
  for (const uid of ids) {
    const job = await deps.jobs.begin(uid);
    if (job.error) {
      failed++;
      continue;
    }
    const done = await finish(uid, job.apple, { ...deps, user: () => Promise.reject(new Error("unused")) });
    if (done.ok) {
      finished++;
      if (done.apple && !done.apple.revoked) appleNotRevoked++;
    } else {
      failed++;
      await deps.jobs.failed(uid, `${done.stage}: ${done.error}`, null).catch(() => {});
    }
  }
  log(`delete-account (scheduled): ${ids.length} due, ${finished} finished, ${failed} still unfinished`);
  return { status: failed > 0 ? 500 : 200, body: { due: ids.length, finished, failed, apple_not_revoked: appleNotRevoked } };
}
