import { assertEquals } from "jsr:@std/assert@1";
import { pushAlert } from "./push.ts";

Deno.test("a message without previews names the sender only", () => {
  assertEquals(pushAlert({ kind: "message", actor_name: "Omar K", preview: null }), { body: "Omar K sent you a message" });
});

Deno.test("a message with a preview shows the text under the sender", () => {
  assertEquals(pushAlert({ kind: "message", actor_name: "Omar K", preview: "Meet at the usual spot?" }), {
    title: "Omar K",
    body: "Meet at the usual spot?",
  });
});

Deno.test("a request never shows text, even if a preview slipped through", () => {
  assertEquals(pushAlert({ kind: "message_request", actor_name: "@pat", preview: "my number is…" }), {
    body: "@pat wants to send you a message",
  });
});

Deno.test("reminders don't name anyone", () => {
  assertEquals(pushAlert({ kind: "meet_starting_soon", actor_name: "Omar K", preview: null }), { body: "Your meet starts soon" });
});

Deno.test("unknown kinds get neutral copy", () => {
  assertEquals(pushAlert({ kind: "something_new", actor_name: null, preview: null }), { body: "New activity" });
});
