// Test doubles shared by storage_cleanup_test.ts and delete_account_test.ts.
// Not imported by any function.
import type { BucketClient, StorageClient, StorageEntry, StorageFailure } from "./storage_cleanup.ts";

export function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

export function assertEquals<T>(actual: T, expected: T, message = "") {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`${message} expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

type Fault = {
  op: "list" | "remove";
  bucket?: string;
  /** Only calls whose prefix (list) or first path (remove) starts with this. */
  path?: string;
  /** Only list calls at this offset. */
  offset?: number;
  /** How many matching calls fail; Infinity = always. */
  times: number;
  error?: StorageFailure;
  /** Throw instead of returning an error (a dropped connection). */
  throws?: boolean;
};

/**
 * In-memory Storage that answers `list` the way Storage does: one page of
 * the entries directly inside a folder, files and folders (`id: null`)
 * together, sorted by name, honoring limit and offset.
 */
export class FakeStorage implements StorageClient {
  readonly objects = new Map<string, Set<string>>();
  readonly calls: { op: "list" | "remove"; bucket: string; path: string; offset?: number; limit?: number; count?: number }[] = [];
  readonly faults: Fault[] = [];
  /** Runs after every successful remove call (to simulate concurrent uploads). */
  afterRemove?: (bucket: string) => void;

  add(bucket: string, ...paths: string[]) {
    if (!this.objects.has(bucket)) this.objects.set(bucket, new Set());
    for (const path of paths) this.objects.get(bucket)!.add(path);
  }

  files(bucket: string, root?: string): string[] {
    return [...(this.objects.get(bucket) ?? [])].filter((p) => root === undefined || p.startsWith(`${root}/`)).sort();
  }

  fail(fault: Fault) {
    this.faults.push(fault);
  }

  private fault(op: "list" | "remove", bucket: string, path: string, offset?: number): Fault | null {
    const match = this.faults.find((f) =>
      f.times > 0 && f.op === op && (f.bucket === undefined || f.bucket === bucket) &&
      (f.path === undefined || path.startsWith(f.path)) && (f.offset === undefined || f.offset === offset)
    );
    if (!match) return null;
    match.times -= 1;
    return match;
  }

  from(bucket: string): BucketClient {
    return {
      list: (prefix, options) => {
        this.calls.push({ op: "list", bucket, path: prefix, offset: options.offset, limit: options.limit });
        const fault = this.fault("list", bucket, prefix, options.offset);
        if (fault?.throws) return Promise.reject(new TypeError("error sending request: connection reset"));
        if (fault) return Promise.resolve({ data: null, error: fault.error ?? { message: "Internal Server Error", status: 500 } });
        const base = prefix === "" ? "" : `${prefix}/`;
        const entries = new Map<string, StorageEntry>();
        for (const path of this.objects.get(bucket) ?? []) {
          if (!path.startsWith(base)) continue;
          const rest = path.slice(base.length);
          const slash = rest.indexOf("/");
          if (slash === -1) entries.set(rest, { name: rest, id: crypto.randomUUID() });
          else entries.set(rest.slice(0, slash), { name: rest.slice(0, slash), id: null });
        }
        const sorted = [...entries.values()].sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
        return Promise.resolve({ data: sorted.slice(options.offset, options.offset + options.limit), error: null });
      },
      remove: (paths) => {
        this.calls.push({ op: "remove", bucket, path: paths[0] ?? "", count: paths.length });
        const fault = this.fault("remove", bucket, paths[0] ?? "");
        if (fault?.throws) return Promise.reject(new TypeError("error sending request: connection reset"));
        if (fault) return Promise.resolve({ data: null, error: fault.error ?? { message: "Internal Server Error", status: 500 } });
        const set = this.objects.get(bucket) ?? new Set<string>();
        const deleted = paths.filter((p) => set.delete(p)).map((name) => ({ name }));
        this.afterRemove?.(bucket);
        return Promise.resolve({ data: deleted, error: null });
      },
    };
  }
}

/** Records waits instead of sleeping. */
export function fakeSleep() {
  const waits: number[] = [];
  return { waits, sleep: (ms: number) => { waits.push(ms); return Promise.resolve(); } };
}
