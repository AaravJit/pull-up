// What the moderation-worker sends to the owner's endpoint. Kept free of
// anything private: report ids, reasons, kinds, priorities, times and queue
// counts only. Never the reported text, media, names or account ids, since
// the endpoint is often a third-party chat webhook. The moderator opens
// the report itself with public.mod_report (docs/MODERATION_RUNBOOK.md).

export type PendingReport = {
  report_id: string;
  reason: string;
  priority: string;
  content_kind: string | null;
  created_at: string;
  attempts: number;
};

export type QueueSummary = {
  open: number;
  urgent_open: number;
  oldest_open_at: string | null;
  open_over_24h: number;
  deliveries_pending: number;
  deliveries_failed: number;
  media_due: number;
  terms: number;
  moderators: number;
};

/** The configured endpoint, if it's a usable https URL. */
export function webhookTarget(raw: string | undefined | null): URL | null {
  const value = raw?.trim();
  if (!value) return null;
  try {
    const url = new URL(value);
    return url.protocol === "https:" && url.hostname.includes(".") ? url : null;
  } catch {
    return null;
  }
}

function plural(n: number, word: string): string {
  return `${n} ${word}${n === 1 ? "" : "s"}`;
}

function queueLine(summary: QueueSummary): string {
  const parts = [`Open queue: ${summary.open}`];
  if (summary.urgent_open > 0) parts.push(`${summary.urgent_open} urgent`);
  if (summary.open_over_24h > 0) parts.push(`${summary.open_over_24h} older than 24 h`);
  if (summary.deliveries_failed > 0) parts.push(`${plural(summary.deliveries_failed, "alert")} failed to deliver`);
  if (summary.terms === 0) parts.push("text filter has no terms");
  return parts.join(", ") + ".";
}

const howTo = "Open it with: select * from public.mod_queue();";

/**
 * One message for a batch of new reports. `text` suits Slack and most chat
 * webhooks, `content` suits Discord; `reports` and `summary` are for an
 * endpoint of the owner's own.
 */
export function alertPayload(reports: PendingReport[], summary: QueueSummary, environment: string) {
  const urgent = reports.filter((r) => r.priority === "urgent").length;
  const reasons = [...new Set(reports.map((r) => r.reason))].join(", ");
  const env = environment ? ` (${environment})` : "";
  const head = `Pull Up moderation${env}: ${plural(reports.length, "new report")}` +
    (urgent > 0 ? `, ${urgent} urgent` : "") + ` (${reasons}).`;
  const text = `${head} ${queueLine(summary)} ${howTo}`;
  return {
    text,
    content: text,
    kind: "pullup.moderation.reports",
    reports: reports.map((r) => ({
      id: r.report_id,
      reason: r.reason,
      priority: r.priority,
      content_kind: r.content_kind,
      created_at: r.created_at,
    })),
    summary,
  };
}

/** The daily reminder, sent only while something needs attention. */
export function digestPayload(summary: QueueSummary, environment: string) {
  if (summary.open === 0 && summary.deliveries_failed === 0 && summary.terms > 0) return null;
  const env = environment ? ` (${environment})` : "";
  const oldest = summary.oldest_open_at ? ` Oldest open report: ${summary.oldest_open_at}.` : "";
  const text = `Pull Up moderation${env} daily check. ${queueLine(summary)}${oldest} ${howTo}`;
  return { text, content: text, kind: "pullup.moderation.digest", summary };
}

/** Hex HMAC-SHA256 of the body, sent as x-pullup-signature when a secret is set. */
export async function signature(secret: string, body: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body)));
  return "sha256=" + Array.from(mac, (b) => b.toString(16).padStart(2, "0")).join("");
}
