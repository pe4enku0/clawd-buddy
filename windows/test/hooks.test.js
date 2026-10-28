// Tests for the Claude Code hook plumbing: payload normalisation and settings.json surgery.
//
//   cd windows && npm test
//
// The built-in Node test runner is used on purpose: this project ships no dependencies.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const test = require("node:test");

// hooks.js resolves ~/.claude/settings.json once, at require time, from os.homedir().
// Redirect HOME before requiring it, so the tests never touch the real settings file.
const home = fs.mkdtempSync(path.join(os.tmpdir(), "clawdbuddy-"));
process.env.HOME = home;
process.env.USERPROFILE = home; // os.homedir() reads either, depending on the platform
const hooks = require("../src/hooks");

const SETTINGS = path.join(home, ".claude", "settings.json");
const BACKUP = `${SETTINGS}.bak-clawdbuddy`;
const TOKEN = "0123456789abcdef0123456789abcdef0123456789abcdef";
const OUR_URL = `http://127.0.0.1:47321/hook/${TOKEN}`;
const EVENTS = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUseFailure", "Stop", "Notification"];

hooks.setToken(TOKEN);

test.after(() => fs.rmSync(home, { recursive: true, force: true }));

const ourHook = (url = OUR_URL) => ({ type: "http", url, timeout: 2 });
const foreignHook = (command = "my-notifier --ping") => ({ type: "command", command });

function writeSettings(value) {
  fs.mkdirSync(path.dirname(SETTINGS), { recursive: true });
  fs.writeFileSync(SETTINGS, `${JSON.stringify(value, null, 2)}\n`);
}
const readSettings = () => JSON.parse(fs.readFileSync(SETTINGS, "utf8"));
function reset() {
  fs.rmSync(SETTINGS, { force: true });
  fs.rmSync(BACKUP, { force: true });
}

test("normalize: file tools show only the file name", () => {
  assert.equal(hooks.normalize({ tool_name: "Edit", tool_input: { file_path: "/a/b/App.tsx" } }).detail, "App.tsx");
  assert.equal(hooks.normalize({ tool_name: "Read", tool_input: { file_path: "C:\\a\\b\\main.rs" } }).detail, "main.rs");
  assert.equal(hooks.normalize({ tool_name: "NotebookEdit", tool_input: { notebook_path: "/a/nb.ipynb" } }).detail, "nb.ipynb");
});

test("normalize: Bash keeps only the first line, trimmed and bounded", () => {
  assert.equal(hooks.normalize({ tool_name: "Bash", tool_input: { command: "  npm test  \nrm -rf /" } }).detail, "npm test");

  const long = hooks.normalize({ tool_name: "Bash", tool_input: { command: "x".repeat(200) } }).detail;
  assert.equal(long.length, 34);
  assert.ok(long.endsWith("…"));
});

test("normalize: search, web and agent tools get short details", () => {
  assert.equal(hooks.normalize({ tool_name: "Grep", tool_input: { pattern: "TODO" } }).detail, "TODO");
  assert.equal(hooks.normalize({ tool_name: "WebFetch", tool_input: { url: "https://example.com/a/b" } }).detail, "example.com");
  assert.equal(hooks.normalize({ tool_name: "WebFetch", tool_input: { url: "not a url" } }).detail, "");
  assert.equal(hooks.normalize({ tool_name: "Task", tool_input: { description: "look around" } }).detail, "look around");
});

test("normalize: MCP tools keep the last name segment, unknown tools keep their name", () => {
  assert.equal(hooks.normalize({ tool_name: "mcp__github__create_issue" }).detail, "create_issue");
  assert.equal(hooks.normalize({ tool_name: "SomeFutureTool" }).detail, "SomeFutureTool");
});

test("normalize: a payload with no fields still produces every key", () => {
  assert.deepEqual(hooks.normalize({}), { event: "", tool: "", detail: "", message: "", kind: "" });
});

test("install: a group shared with somebody else's hook keeps that hook", () => {
  reset();
  writeSettings({ hooks: { Stop: [{ hooks: [foreignHook(), ourHook("http://127.0.0.1:47321/hook")] }] } });

  hooks.install();

  const stop = readSettings().hooks.Stop;
  assert.equal(stop.length, 2, "the shared group survives, next to the fresh one");
  assert.deepEqual(stop[0].hooks, [foreignHook()]);
  assert.equal(stop.flatMap((g) => g.hooks).filter((h) => h.url === OUR_URL).length, 1);
});

test("install: an entry from a version without a token is replaced, not duplicated", () => {
  reset();
  writeSettings({ hooks: { Stop: [{ hooks: [ourHook("http://127.0.0.1:47321/hook")] }] } });

  hooks.install();

  const urls = readSettings().hooks.Stop.flatMap((g) => g.hooks.map((h) => h.url));
  assert.deepEqual(urls, [OUR_URL]);
});

test("uninstall: a group shared with somebody else's hook is not deleted", () => {
  reset();
  writeSettings({ hooks: { Stop: [{ hooks: [foreignHook(), ourHook()] }] } });

  hooks.uninstall();

  assert.deepEqual(readSettings().hooks.Stop, [{ hooks: [foreignHook()] }]);
});

test("uninstall: a malformed hook list is left exactly as it was", () => {
  reset();
  writeSettings({ hooks: { Stop: "nonsense" }, other: 1 });

  hooks.uninstall();

  assert.deepEqual(readSettings(), { hooks: { Stop: "nonsense" }, other: 1 });
});

test("install: wires every event, keeps other settings, and never duplicates", () => {
  reset();
  writeSettings({ permissions: { allow: ["Bash"] }, hooks: { Stop: [{ hooks: [foreignHook()] }] } });

  hooks.install();
  hooks.install(); // second run must not append a second copy

  const s = readSettings();
  assert.deepEqual(s.permissions, { allow: ["Bash"] });
  for (const event of EVENTS) {
    const mine = s.hooks[event].filter((g) => g.hooks.some((h) => h.url === OUR_URL));
    assert.equal(mine.length, 1, `${event} should be wired exactly once`);
  }
  // Tool events need a matcher, lifecycle events must not carry one.
  assert.equal(s.hooks.PreToolUse.at(-1).matcher, "*");
  assert.equal(s.hooks.Stop.find((g) => g.hooks.some((h) => h.url === OUR_URL)).matcher, undefined);
  assert.ok(s.hooks.Stop.some((g) => g.hooks.some((h) => h.command === "my-notifier --ping")));
  assert.ok(fs.existsSync(BACKUP));
});

test("install: the backup is written once and never overwritten", () => {
  reset();
  writeSettings({ hooks: {} });
  hooks.install();

  const original = fs.readFileSync(BACKUP, "utf8");
  writeSettings({ hooks: {}, changed: true });
  hooks.install();
  assert.equal(fs.readFileSync(BACKUP, "utf8"), original);
});

test("install: creates ~/.claude when it does not exist yet", () => {
  reset();
  fs.rmSync(path.dirname(SETTINGS), { recursive: true, force: true });
  hooks.install();
  assert.ok(fs.existsSync(SETTINGS));
  assert.equal(hooks.status().installed, true);
});

test("uninstall: removes only our hooks and prunes what is left empty", () => {
  reset();
  writeSettings({ hooks: { Stop: [{ hooks: [foreignHook()] }], PreToolUse: [] } });
  hooks.install();
  hooks.uninstall();

  const s = readSettings();
  assert.deepEqual(s.hooks.Stop, [{ hooks: [foreignHook()] }]);
  assert.equal("PreToolUse" in s.hooks, false);
  assert.equal(hooks.status().installed, false);
});

test("status: reports installed, outdated and broken files", () => {
  reset();
  assert.equal(hooks.status().installed, false);
  assert.equal(hooks.status().error, false);

  writeSettings({ hooks: { Stop: [{ hooks: [ourHook("http://127.0.0.1:47321/hook/oldtoken")] }] } });
  const stale = hooks.status();
  assert.equal(stale.installed, false);
  assert.equal(stale.outdated, true);

  fs.writeFileSync(SETTINGS, "{ not json");
  const broken = hooks.status();
  assert.equal(broken.installed, false);
  assert.equal(broken.error, true);
});
