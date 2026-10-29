// Asks the local `claude -p` (the user's own login, no API key) with only the Read tool, from a
// throwaway folder, streaming the answer. Port of macos/Sources/ClaudeRunner.swift.
//
// `--setting-sources project` keeps the user's own settings out: their broad allow rules can't
// widen Read, and our own hooks in ~/.claude/settings.json don't load, so the crab doesn't react
// to its own questions (the hooks are HTTP here, an environment variable couldn't switch them off).
const { spawn } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const TIMEOUT_MS = 120_000;
const SYSTEM_PROMPT =
  "You are Clawd, a friendly pixel crab who lives in the corner of the screen and helps while the user codes. " +
  "Answer briefly and clearly: usually 1-4 sentences, at most a short list or a small code snippet. " +
  "Plain text; use Markdown only for `code`. Reply in the language of the user's message. " +
  "You can only read files, never change anything or run commands.";

const ARGS = [
  "-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
  "--tools", "Read", "--allowedTools", "Read(./**)", "--permission-mode", "dontAsk",
  "--setting-sources", "project", "--no-session-persistence", "--strict-mcp-config",
  "--disable-slash-commands", "--model", "sonnet", "--system-prompt", SYSTEM_PROMPT,
];

const isFile = (p) => { try { return fs.statSync(p).isFile(); } catch { return false; } };
const byVersionDesc = (a, b) => b.localeCompare(a, undefined, { numeric: true });

/** Where Claude Code may be, best first: CLI installs, then the newest editor-extension copy, then npm. */
function candidates({ platform = process.platform, home = os.homedir(), env = process.env, readdir = fs.readdirSync } = {}) {
  const win = platform === "win32";
  const exe = win ? "claude.exe" : "claude";
  const join = win ? path.win32.join : path.posix.join;
  const list = [];
  const binary = (p) => list.push({ command: p, args: [] });

  binary(join(home, ".local", "bin", exe));
  if (!win) for (const p of [join(home, ".claude", "local", "claude"), "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]) binary(p);
  for (const dir of (env.PATH || env.Path || "").split(win ? ";" : ":").filter(Boolean)) binary(join(dir, exe));
  for (const editor of [".vscode", ".vscode-oss", ".vscode-insiders", ".cursor", ".windsurf"]) {
    const ext = join(home, editor, "extensions");
    let names = [];
    try { names = readdir(ext).filter((n) => n.startsWith("anthropic.claude-code-")).sort(byVersionDesc); } catch {}
    for (const n of names) binary(join(ext, n, "resources", "native-binary", exe));
  }
  // An npm install is a JS entry point; Electron's own runtime can run it, so no separate Node is needed.
  if (win && env.APPDATA) {
    list.push({
      command: process.execPath, node: true,
      args: [join(env.APPDATA, "npm", "node_modules", "@anthropic-ai", "claude-code", "cli.js")],
    });
  }
  return list;
}

function locate(opts) {
  return candidates(opts).find((c) => isFile(c.node ? c.args[0] : c.command)) || null;
}

/**
 * Reads one line of stream-json output.
 * Returns { delta } for streamed text, { final } / { failure } for the closing result, or null.
 */
function parseLine(line) {
  let j;
  try { j = JSON.parse(line); } catch { return null; }
  if (j.type === "stream_event") {
    const e = j.event || {}, d = e.delta || {};
    if (e.type === "content_block_delta" && d.type === "text_delta" && typeof d.text === "string") return { delta: d.text };
    return null;
  }
  if (j.type === "result") {
    const r = typeof j.result === "string" ? j.result : "";
    if (j.is_error === true || (j.subtype || "success") !== "success") return { failure: r || j.subtype || "error" };
    return { final: r };
  }
  return null;
}

/** Turns an error into one of the messages the user can act on. */
function classify(raw) {
  const s = String(raw).toLowerCase();
  const has = (words) => words.some((w) => s.includes(w));
  if (has(["/login", "log in", "logged in", "not authenticated", "authentication", "oauth", "401", "api key"])) return { kind: "notLoggedIn" };
  if (has(["network", "enotfound", "econnrefused", "econnreset", "fetch failed", "getaddrinfo",
    "connection error", "unable to connect", "offline", "etimedout"])) return { kind: "offline" };
  const line = (String(raw).split("\n")[0] || "").trim();
  return { kind: "other", detail: line.length > 160 ? line.slice(0, 159) + "…" : line };
}

/**
 * Asks one question. `files` are copied into the run's folder so Read can reach them.
 * onText(answerSoFar) streams; onDone({ ok, text } | { ok: false, error }) ends it.
 * Returns a cancel function; after cancelling, no callback fires.
 */
function ask(prompt, { files = [], onText = () => {}, onDone = () => {}, locator = locate } = {}) {
  const found = locator();
  if (!found) { onDone({ ok: false, error: { kind: "notFound" } }); return () => {}; }

  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "ClawdNotch-"));
  for (const f of files) {
    try { fs.copyFileSync(f, path.join(dir, path.basename(f))); } catch {}
  }
  const env = { ...process.env, CLAWD_NOTCH_INTERNAL: "1" };
  if (found.node) env.ELECTRON_RUN_AS_NODE = "1";

  let child, timer;
  let finished = false;
  const cleanUp = () => { try { fs.rmSync(dir, { recursive: true, force: true }); } catch {} };
  const finish = (result) => {
    if (finished) return;
    finished = true;
    clearTimeout(timer);
    cleanUp();
    onDone(result);
  };

  try {
    child = spawn(found.command, [...found.args, ...ARGS], { cwd: dir, env, windowsHide: true });
  } catch {
    cleanUp();
    onDone({ ok: false, error: { kind: "notFound" } });
    return () => {};
  }

  let text = "", final = null, failure = null, errText = "", pending = "";
  const consume = (chunk) => {
    pending += chunk;
    let nl;
    while ((nl = pending.indexOf("\n")) >= 0) {
      const r = parseLine(pending.slice(0, nl));
      pending = pending.slice(nl + 1);
      if (!r) continue;
      if (r.delta !== undefined) { text += r.delta; if (!finished) onText(text); }
      if (r.final !== undefined) final = r.final;
      if (r.failure !== undefined) failure = r.failure;
    }
  };
  child.stdout.setEncoding("utf8");
  child.stdout.on("data", consume);
  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (s) => { errText += s; });
  child.on("error", (e) => finish({ ok: false, error: e.code === "ENOENT" ? { kind: "notFound" } : classify(e.message) }));
  child.on("close", (code) => {
    consume("\n");
    if (final) finish({ ok: true, text: final });
    else if (failure) finish({ ok: false, error: classify(failure) });
    else if (text) finish({ ok: true, text });
    else finish({ ok: false, error: classify(errText || `exit ${code}`) });
  });
  child.stdin.on("error", () => {});
  child.stdin.end(prompt);

  timer = setTimeout(() => {
    if (finished) return;
    child.kill();
    finish({ ok: false, error: { kind: "timeout" } });
  }, TIMEOUT_MS);

  return () => {
    if (finished) return;
    finished = true;
    clearTimeout(timer);
    child.kill();
    cleanUp();
  };
}

module.exports = { ask, locate, candidates, parseLine, classify, ARGS };
