// Tests for the hook input path: byte-accurate body decoding and bounded payload fields.
//
//   cd windows && npm test
const assert = require("node:assert/strict");
const { PassThrough } = require("node:stream");
const test = require("node:test");
const hooks = require("../src/hooks");

/** Feeds `text` to readBody in the given chunks, cut at byte offsets in `cuts`. */
function feed(text, cuts = [], limit) {
  const bytes = Buffer.from(text, "utf8");
  const stream = new PassThrough();
  const body = hooks.readBody(stream, limit);
  let at = 0;
  for (const cut of cuts) {
    stream.write(bytes.subarray(at, cut));
    at = cut;
  }
  stream.end(bytes.subarray(at));
  return body;
}

test("readBody joins chunks without mangling multi-byte characters", async () => {
  const payload = JSON.stringify({ message: "Привет, краб 🦀 — тест", tool_name: "Bash" });
  const emojiAt = Buffer.from(payload, "utf8").indexOf(Buffer.from("🦀", "utf8"));

  // Cut in the middle of the emoji: a string concat would decode half a character twice.
  const splitMidEmoji = await feed(payload, [emojiAt + 2]);
  assert.equal(splitMidEmoji, payload);

  // Many small chunks, as a slow local pipe would deliver them.
  const cuts = [];
  for (let i = 1; i < Buffer.byteLength(payload); i += 3) cuts.push(i);
  assert.equal(await feed(payload, cuts), payload);
});

test("readBody returns a body that still parses", async () => {
  const event = { hook_event_name: "Notification", message: "Разрешение: нужно подтверждение" };
  const payload = JSON.stringify(event);
  const parsed = JSON.parse(await feed(payload, [10, 20]));
  assert.deepEqual(parsed, event);
});

test("readBody rejects a body over the limit instead of buffering it", async () => {
  await assert.rejects(() => feed("x".repeat(64), [], 16), /too large/);
});

test("normalize bounds the message that goes into the bubble", () => {
  const long = hooks.normalize({ message: "я".repeat(5000) });
  assert.equal(long.message.length, 160);
  assert.ok(long.message.endsWith("…"));

  const short = hooks.normalize({ message: "нет" });
  assert.equal(short.message, "нет");

  assert.equal(hooks.normalize({}).message, "");
});
