// Push wording for send-push. Kept apart from the handler so it can be unit
// tested without APNs.

// What the database says may be pushed (public.push_content): the
// recipient's preferences are applied there, and `preview` is set only when
// they turned message previews on for an accepted conversation.
export interface PushContent {
  recipient_id: string;
  kind: string;
  conversation_id: string | null;
  already_pushed: boolean;
  allowed: boolean;
  actor_name: string | null;
  preview: string | null;
}

const COPY: Record<string, string> = {
  follow: "started following you",
  follow_request: "wants to follow you",
  like: "liked your post",
  comment: "commented on your post",
  meet_rsvp: "is going to your meet",
  meet_updated: "updated a meet you're going to",
  meet_cancelled: "cancelled a meet you were going to",
  meet_starting_soon: "Your meet starts soon",
  drive_validated: "Your drive has been checked",
  // Without previews, never the message itself.
  message: "sent you a message",
  message_request: "wants to send you a message",
};

// The banner. With a preview the sender is the title and the message the
// body; otherwise one line that never contains message text.
export function pushAlert(row: Pick<PushContent, "kind" | "actor_name" | "preview">): { title?: string; body: string } {
  if (row.kind === "message" && row.preview && row.actor_name) {
    return { title: row.actor_name, body: row.preview };
  }
  const text = COPY[row.kind] ?? "New activity";
  return { body: row.actor_name && !text.startsWith("Your") ? `${row.actor_name} ${text}` : text };
}
