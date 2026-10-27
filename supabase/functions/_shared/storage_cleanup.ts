// Removes every Storage object under a folder, for account deletion.
//
// Storage has no recursive delete and `list` returns one page of one folder:
// files and, as entries with `id: null`, the folders directly inside it. So
// a folder is walked page by page (offset + limit until a short page) and
// every subfolder is walked the same way, all before anything is removed,
// because removing while paging shifts the offsets and skips files. Files
// are then removed in batches. Every list and remove call is retried on
// transient failures with bounded exponential backoff.
//
// After removing, the folder is walked again: removal is only reported done
// once a walk finds nothing (this also catches a file uploaded mid-way).
// Any failure is returned, never swallowed, and the caller keeps the account
// so that calling again picks up whatever is left: nothing here depends on
// state from an earlier run.
//
// The client is an interface so tests can run without a Supabase project;
// `admin.storage` from supabase-js satisfies it.

export interface StorageEntry {
  name: string;
  /** null for a folder. */
  id: string | null;
}

export interface StorageFailure {
  message: string;
  /** HTTP status, when Storage answered (StorageApiError). */
  status?: number;
  statusCode?: string;
}

export interface BucketClient {
  list(
    prefix: string,
    options: { limit: number; offset: number; sortBy: { column: string; order: string } },
  ): Promise<{ data: StorageEntry[] | null; error: StorageFailure | null }>;
  remove(paths: string[]): Promise<{ data: unknown; error: StorageFailure | null }>;
}

export interface StorageClient {
  from(bucket: string): BucketClient;
}

export interface CleanupOptions {
  /** Entries asked for per list call. */
  pageSize?: number;
  /** Paths per remove call. */
  removeBatch?: number;
  /** Tries per call, the first included. */
  attempts?: number;
  /** Wait before the first retry; doubles each time. */
  baseDelayMs?: number;
  /** Remove-then-walk rounds before giving up on a folder that keeps refilling. */
  maxRounds?: number;
  sleep?: (ms: number) => Promise<void>;
}

export type CleanupResult =
  | { ok: true; removed: number }
  | { ok: false; removed: number; error: string };

const defaults = {
  pageSize: 1000,
  removeBatch: 500,
  attempts: 4,
  baseDelayMs: 250,
  maxRounds: 3,
  sleep: (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms)),
};

/** A 4xx other than timeout or rate limit won't change on retry. */
export function isTransient(error: StorageFailure): boolean {
  const status = error.status ?? (error.statusCode ? Number(error.statusCode) : undefined);
  if (status === undefined || Number.isNaN(status)) return true; // network or unknown
  return status >= 500 || status === 408 || status === 429;
}

/**
 * Calls `op` until it succeeds, fails permanently, or runs out of attempts.
 * A thrown error counts as a transient failure.
 */
export async function withRetry<T extends { error: StorageFailure | null }>(
  op: () => Promise<T>,
  options: Pick<CleanupOptions, "attempts" | "baseDelayMs" | "sleep"> = {},
): Promise<T | { data: null; error: StorageFailure }> {
  const attempts = Math.max(1, options.attempts ?? defaults.attempts);
  const baseDelayMs = options.baseDelayMs ?? defaults.baseDelayMs;
  const sleep = options.sleep ?? defaults.sleep;
  let last: T | { data: null; error: StorageFailure } = { data: null, error: { message: "not attempted" } };
  for (let attempt = 1; attempt <= attempts; attempt++) {
    try {
      last = await op();
    } catch (thrown) {
      last = { data: null, error: { message: thrown instanceof Error ? thrown.message : String(thrown) } };
    }
    if (!last.error || !isTransient(last.error) || attempt === attempts) return last;
    await sleep(baseDelayMs * 2 ** (attempt - 1));
  }
  return last;
}

const join = (prefix: string, name: string) => (prefix === "" ? name : `${prefix}/${name}`);

/** Every file path under `root`, however deep. */
export async function listTree(
  bucket: BucketClient,
  root: string,
  options: CleanupOptions = {},
): Promise<{ files: string[]; error: string | null }> {
  const pageSize = options.pageSize ?? defaults.pageSize;
  const files: string[] = [];
  const folders = [root];
  while (folders.length > 0) {
    const prefix = folders.pop()!;
    for (let offset = 0;; offset += pageSize) {
      const { data, error } = await withRetry(
        () => bucket.list(prefix, { limit: pageSize, offset, sortBy: { column: "name", order: "asc" } }),
        options,
      );
      if (error) return { files, error: `listing ${prefix} (offset ${offset}): ${error.message}` };
      const page = data ?? [];
      for (const entry of page) {
        if (entry.id === null) folders.push(join(prefix, entry.name));
        else files.push(join(prefix, entry.name));
      }
      if (page.length < pageSize) break;
    }
  }
  return { files, error: null };
}

/** Removes everything under `root` in `bucket`, then checks nothing is left. */
export async function removeTree(
  storage: StorageClient,
  bucketName: string,
  root: string,
  options: CleanupOptions = {},
): Promise<CleanupResult> {
  if (root === "" || root.includes("..")) return { ok: false, removed: 0, error: `refusing to remove "${root}"` };
  const bucket = storage.from(bucketName);
  const batch = options.removeBatch ?? defaults.removeBatch;
  const maxRounds = options.maxRounds ?? defaults.maxRounds;
  let removed = 0;
  for (let round = 0;; round++) {
    const { files, error } = await listTree(bucket, root, options);
    if (error) return { ok: false, removed, error: `${bucketName}: ${error}` };
    if (files.length === 0) return { ok: true, removed };
    if (round === maxRounds) {
      return { ok: false, removed, error: `${bucketName}/${root}: ${files.length} files still there after ${maxRounds} rounds` };
    }
    for (let i = 0; i < files.length; i += batch) {
      const chunk = files.slice(i, i + batch);
      const { data, error: removeError } = await withRetry(() => bucket.remove(chunk), options);
      if (removeError) return { ok: false, removed, error: `${bucketName}: removing ${chunk.length} files: ${removeError.message}` };
      // Storage answers with the objects it deleted; the next walk checks the rest.
      removed += Array.isArray(data) ? data.length : chunk.length;
    }
  }
}
