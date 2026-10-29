// The chat's plumbing: reading claude's stream, naming errors, finding claude.exe, shortcut checks.
const test = require("node:test");
const assert = require("node:assert/strict");
const { parseLine, classify, candidates, ARGS } = require("../src/claude.js");
const { isHotkey } = require("../src/prefs.js");

test("streamed text deltas are picked up", () => {
  const line = JSON.stringify({ type: "stream_event", event: { type: "content_block_delta", delta: { type: "text_delta", text: "Привет" } } });
  assert.deepEqual(parseLine(line), { delta: "Привет" });
});

test("other stream events and junk are ignored", () => {
  assert.equal(parseLine(JSON.stringify({ type: "stream_event", event: { type: "message_start" } })), null);
  assert.equal(parseLine(JSON.stringify({ type: "system", subtype: "init" })), null);
  assert.equal(parseLine("not json"), null);
});

test("the result line ends the answer, or reports the failure", () => {
  assert.deepEqual(parseLine(JSON.stringify({ type: "result", subtype: "success", result: "ok" })), { final: "ok" });
  assert.deepEqual(parseLine(JSON.stringify({ type: "result", is_error: true, result: "Invalid API key · Please run /login" })),
    { failure: "Invalid API key · Please run /login" });
});

test("errors turn into something the user can act on", () => {
  assert.equal(classify("Invalid API key · Please run /login").kind, "notLoggedIn");
  assert.equal(classify("TypeError: fetch failed").kind, "offline");
  assert.deepEqual(classify("weird\nstack"), { kind: "other", detail: "weird" });
});

test("the internal call can only Read inside its own folder and ignores user settings", () => {
  const after = (flag) => ARGS[ARGS.indexOf(flag) + 1];
  assert.equal(after("--tools"), "Read");
  assert.equal(after("--allowedTools"), "Read(./**)");
  assert.equal(after("--permission-mode"), "dontAsk");
  assert.equal(after("--setting-sources"), "project");
});

test("on Windows, the native install comes first and the newest extension wins", () => {
  const home = "C:\\Users\\me";
  const list = candidates({
    platform: "win32", home, env: { Path: "C:\\tools", APPDATA: "C:\\Users\\me\\AppData\\Roaming" },
    readdir: (dir) => (dir.endsWith(".vscode\\extensions")
      ? ["anthropic.claude-code-2.1.9-win32-x64", "anthropic.claude-code-2.1.310-win32-x64", "other.ext"] : []),
  });
  assert.equal(list[0].command, "C:\\Users\\me\\.local\\bin\\claude.exe");
  assert.equal(list[1].command, "C:\\tools\\claude.exe");
  assert.equal(list[2].command, "C:\\Users\\me\\.vscode\\extensions\\anthropic.claude-code-2.1.310-win32-x64\\resources\\native-binary\\claude.exe");
  const npm = list[list.length - 1];
  assert.equal(npm.node, true);
  assert.match(npm.args[0], /npm\\node_modules\\@anthropic-ai\\claude-code\\cli\.js$/);
});

test("shortcuts need Ctrl, Alt or Win", () => {
  for (const ok of ["Control+Alt+Space", "Control+Shift+K", "Alt+F2", "Super+Alt+Up"]) assert.ok(isHotkey(ok), ok);
  for (const bad of ["Space", "Shift+A", "Control+", "Control+Alt+Space; rm", "Control+Ä", 42]) assert.ok(!isHotkey(bad), String(bad));
});
