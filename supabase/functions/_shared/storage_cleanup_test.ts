// deno test supabase/functions/_shared/
// Storage cleanup for account deletion, against an in-memory Storage that
// pages and nests like the real one. No network.
import { isTransient, listTree, removeTree } from "./storage_cleanup.ts";
import { assert, assertEquals, FakeStorage, fakeSleep } from "./test_fakes.ts";

const uid = "0b6f3e3e-9c1d-4b6a-8f6e-2a1d3c4b5e6f";
const range = (n: number) => Array.from({ length: n }, (_, i) => i);

Deno.test("more than 1,000 files in one folder are all listed and removed", async () => {
  const storage = new FakeStorage();
  storage.add("avatars", ...range(2500).map((i) => `${uid}/avatar-${String(i).padStart(4, "0")}.jpg`));
  const { sleep } = fakeSleep();
  const result = await removeTree(storage, "avatars", uid, { sleep });
  assertEquals(result, { ok: true, removed: 2500 });
  assertEquals(storage.files("avatars"), []);
  // Three pages before anything is removed (removing while paging would skip files) ...
  const firstWalk = storage.calls.slice(0, 3);
  assertEquals(firstWalk.map((c) => [c.op, c.offset, c.limit]), [["list", 0, 1000], ["list", 1000, 1000], ["list", 2000, 1000]]);
  // ... then removal in batches of at most 500 ...
  const removes = storage.calls.filter((c) => c.op === "remove");
  assertEquals(removes.map((c) => c.count), [500, 500, 500, 500, 500]);
  // ... then one more walk that finds nothing.
  assertEquals(storage.calls.at(-1), { op: "list", bucket: "avatars", path: uid, offset: 0, limit: 1000 });
});

Deno.test("exactly 1,000 files: the empty second page ends the listing", async () => {
  const storage = new FakeStorage();
  storage.add("post-media", ...range(1000).map((i) => `${uid}/p/${i}.jpg`));
  const { files, error } = await listTree(storage.from("post-media"), uid);
  assertEquals(error, null);
  assertEquals(files.length, 1000);
  assertEquals(storage.calls.map((c) => [c.path, c.offset]), [[uid, 0], [`${uid}/p`, 0], [`${uid}/p`, 1000]]);
});

Deno.test("nested folders several levels deep, each with more than a page, are removed; neighbours are not", async () => {
  const storage = new FakeStorage();
  const deep: string[] = [];
  let folder = uid;
  for (let level = 1; level <= 6; level++) {
    folder = `${folder}/level-${level}`;
    deep.push(`${folder}/file.jpg`);
  }
  // A wide folder three levels down with 1,001 files, and 1,001 subfolders at the top.
  deep.push(...range(1001).map((i) => `${uid}/level-1/level-2/wide/${i}.jpg`));
  deep.push(...range(1001).map((i) => `${uid}/vehicle-${String(i).padStart(4, "0")}/cover.jpg`));
  deep.push(`${uid}/top.jpg`, `${uid}/.emptyFolderPlaceholder`);
  storage.add("vehicle-media", ...deep);
  // Someone else's files, including a folder whose name starts with the uid.
  const others = [`${uid}0/not-mine.jpg`, `${uid}-x/not-mine.jpg`, `ffffffff-0000-0000-0000-000000000000/${uid}/car.jpg`];
  storage.add("vehicle-media", ...others);

  const result = await removeTree(storage, "vehicle-media", uid, fakeSleep());
  assertEquals(result, { ok: true, removed: deep.length });
  assertEquals(storage.files("vehicle-media"), [...others].sort());
});

Deno.test("a page that fails once is retried after a short wait and the run succeeds", async () => {
  const storage = new FakeStorage();
  storage.add("avatars", ...range(1500).map((i) => `${uid}/${i}.jpg`));
  storage.fail({ op: "list", offset: 1000, times: 1, error: { message: "upstream timeout", status: 504 } });
  storage.fail({ op: "remove", times: 1, throws: true });
  const { waits, sleep } = fakeSleep();
  const result = await removeTree(storage, "avatars", uid, { sleep });
  assertEquals(result, { ok: true, removed: 1500 });
  assertEquals(storage.files("avatars"), []);
  assertEquals(waits, [250, 250], "one backoff for the failed page, one for the dropped remove");
});

Deno.test("a permanent failure is reported after bounded retries, not as success", async () => {
  const storage = new FakeStorage();
  storage.add("post-media", `${uid}/a.jpg`);
  storage.fail({ op: "list", times: Infinity, error: { message: "Internal Server Error", status: 500 } });
  const { waits, sleep } = fakeSleep();
  const result = await removeTree(storage, "post-media", uid, { sleep });
  assert(!result.ok, "reported as a failure");
  assert(result.error.includes("Internal Server Error"), result.error);
  assertEquals(waits, [250, 500, 1000], "four tries, exponential backoff, then stop");
  assertEquals(storage.files("post-media"), [`${uid}/a.jpg`], "nothing removed");
});

Deno.test("a 4xx is not retried", async () => {
  const storage = new FakeStorage();
  storage.add("avatars", `${uid}/a.jpg`);
  storage.fail({ op: "remove", times: Infinity, error: { message: "Bucket not found", statusCode: "404" } });
  const { waits, sleep } = fakeSleep();
  const result = await removeTree(storage, "avatars", uid, { sleep });
  assert(!result.ok && result.error.includes("Bucket not found"), "reported");
  assertEquals(waits, []);
  assertEquals(isTransient({ message: "x", status: 429 }), true);
  assertEquals(isTransient({ message: "x", status: 403 }), false);
  assertEquals(isTransient({ message: "fetch failed" }), true);
});

Deno.test("after a partial failure, running again removes what's left", async () => {
  const storage = new FakeStorage();
  const all = range(1700).map((i) => `${uid}/d/${String(i).padStart(4, "0")}.jpg`);
  storage.add("dm-media", ...all);
  // The second remove batch keeps failing: the first 500 go, the rest stay.
  storage.fail({ op: "remove", path: `${uid}/d/0500`, times: Infinity, error: { message: "Service Unavailable", status: 503 } });
  const first = await removeTree(storage, "dm-media", uid, fakeSleep());
  assert(!first.ok, "the first run fails");
  assertEquals(first.removed, 500);
  assertEquals(storage.files("dm-media").length, 1200);

  storage.faults.length = 0; // Storage recovers
  const second = await removeTree(storage, "dm-media", uid, fakeSleep());
  assertEquals(second, { ok: true, removed: 1200 });
  assertEquals(storage.files("dm-media"), []);
  const third = await removeTree(storage, "dm-media", uid, fakeSleep());
  assertEquals(third, { ok: true, removed: 0 }, "idempotent once empty");
});

Deno.test("a file uploaded during cleanup is caught by the check walk", async () => {
  const storage = new FakeStorage();
  storage.add("avatars", `${uid}/a.jpg`);
  let uploaded = false;
  storage.afterRemove = (bucket) => {
    if (!uploaded) storage.add(bucket, `${uid}/late/b.jpg`);
    uploaded = true;
  };
  assertEquals(await removeTree(storage, "avatars", uid, fakeSleep()), { ok: true, removed: 2 });
  assertEquals(storage.files("avatars"), []);

  // A folder that refills every time is a failure after three rounds, not a loop.
  const busy = new FakeStorage();
  busy.add("avatars", `${uid}/0.jpg`);
  let n = 0;
  busy.afterRemove = (bucket) => busy.add(bucket, `${uid}/${++n}.jpg`);
  const result = await removeTree(busy, "avatars", uid, fakeSleep());
  assert(!result.ok && result.error.includes("still there"), "gives up and says so");
});

Deno.test("refuses an empty or relative root", async () => {
  const storage = new FakeStorage();
  storage.add("avatars", "x/a.jpg");
  assertEquals((await removeTree(storage, "avatars", "", fakeSleep())).ok, false);
  assertEquals((await removeTree(storage, "avatars", "../x", fakeSleep())).ok, false);
  assertEquals(storage.calls, []);
});
