// Claude Code integration: hook payload normalisation and ~/.claude/settings.json install/uninstall.
const fs = require("fs");
const os = require("os");
const path = require("path");

const PORT = 47321;
const HOST = `127.0.0.1:${PORT}`;
const HOOK_BASE = `http://${HOST}/hook`;
const SETTINGS = path.join(os.homedir(), ".claude", "settings.json");
const BACKUP = SETTINGS + ".bak-clawdbuddy";
const EVENTS = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUseFailure", "Stop", "Notification"];
const TOOL_EVENTS = new Set(["PreToolUse", "PostToolUseFailure"]);

// A secret path, so other local programs and web pages can't feed the buddy fake events.
let token = "";
const setToken = (t) => { token = t; };
const hookPath = () => `/hook/${token}`;
const hookUrl = () => `http://${HOST}${hookPath()}`;
// PermissionRequest waits on its own URL for the card's Allow / Deny (see main.js).
const APPROVAL_EVENT = "PermissionRequest";
const APPROVAL_TIMEOUT_S = 30;
const approvePath = () => `${hookPath()}/approve`;
const approveUrl = () => `http://${HOST}${approvePath()}`;
const currentUrl = (event) => (event === APPROVAL_EVENT ? approveUrl() : hookUrl());

const truncate = (s, n) => (s.length > n ? s.slice(0, n - 1) + "…" : s);

// Bodies arrive in TCP-sized chunks, and a chunk boundary can land in the middle of a multi-byte
// character: appending chunks to a string decodes each one on its own and mangles the pair.
// Collect the bytes and decode once. Cyrillic is this app's second language, so it is a normal
// payload, not an edge case.
function readBody(req, limit = 2_000_000) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on("data", (chunk) => {
      size += chunk.length;
      if (size > limit) { reject(new Error("hook payload too large")); req.destroy(); return; }
      chunks.push(chunk);
    });
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}
// Also matches entries from older versions without a token, so they get cleaned up.
const isOurs = (h) => h && h.type === "http" && typeof h.url === "string" && h.url.startsWith(HOOK_BASE);
const hasOurs = (group) => (group.hooks || []).some(isOurs);
const hasCurrent = (group, event) => (group.hooks || []).some((h) => isOurs(h) && h.url === currentUrl(event));

/** Boils a hook payload down to what the buddy needs. Mirrors macos/Sources/HookBridge.swift. */
function normalize(j) {
  const tool = j.tool_name || "";
  const input = j.tool_input || {};
  const str = (k) => (typeof input[k] === "string" ? input[k] : "");
  let detail;
  switch (tool) {
    case "Edit": case "MultiEdit": case "Write": case "Read":
      detail = path.win32.basename(str("file_path")); break;
    case "NotebookEdit":
      detail = path.win32.basename(str("notebook_path")); break;
    case "Bash": case "PowerShell":
      detail = truncate((str("command").split("\n")[0] || "").trim(), 34); break;
    case "Grep": case "Glob":
      detail = truncate(str("pattern"), 28); break;
    case "WebSearch":
      detail = truncate(str("query"), 30); break;
    case "WebFetch":
      try { detail = new URL(str("url")).host; } catch { detail = ""; } break;
    case "Agent": case "Task":
      detail = truncate(str("description"), 30); break;
    default:
      detail = tool.startsWith("mcp__") ? tool.split("__").pop() : tool;
  }
  return {
    event: j.hook_event_name || "", tool, detail,
    message: truncate(typeof j.message === "string" ? j.message : "", 160),
    kind: typeof j.notification_type === "string" ? j.notification_type : "",
  };
}

/**
 * Everything the user would be allowing, untrimmed: a short summary could hide the dangerous part,
 * e.g. the second line of a command. Mirrors approvalDetail in macos/Sources/HookBridge.swift.
 */
function approvalDetail(tool, input = {}) {
  const str = (k) => (typeof input[k] === "string" ? input[k] : "");
  const home = os.homedir();
  const tilde = (p) => (home && p.toLowerCase().startsWith(home.toLowerCase() + path.sep) ? "~" + p.slice(home.length) : p);
  let text;
  switch (tool) {
    case "Bash": case "PowerShell": text = str("command"); break;
    case "Edit": case "MultiEdit": case "Write": case "Read": text = tilde(str("file_path")); break;
    case "NotebookEdit": text = tilde(str("notebook_path")); break;
    case "WebFetch": text = str("url"); break;
    case "WebSearch": text = str("query"); break;
    default: {
      const sorted = (v) => (v && typeof v === "object" && !Array.isArray(v)
        ? Object.fromEntries(Object.keys(v).sort().map((k) => [k, sorted(v[k])])) : v);
      text = JSON.stringify(sorted(input)) || "";
    }
  }
  return text.slice(0, 4000);
}

/**
 * Makes invisible tricks visible: control characters and zero-width / bidi-override marks
 * (which can make "rm -rf ~" read like something harmless). Newlines stay.
 */
function visible(s) {
  let out = "";
  for (const ch of String(s)) {
    const c = ch.codePointAt(0);
    if (c === 0x0a) out += "\n";
    else if (c === 0x09) out += "  ";
    else if (c < 0x20 || (c >= 0x7f && c < 0xa0)) out += `\\x${c.toString(16).toUpperCase().padStart(2, "0")}`;
    else if ((c >= 0x200b && c <= 0x200f) || (c >= 0x202a && c <= 0x202e) || (c >= 0x2060 && c <= 0x2069) || c === 0xfeff) {
      out += `<U+${c.toString(16).toUpperCase().padStart(4, "0")}>`;
    } else out += ch;
  }
  return out;
}

/** The body that answers a PermissionRequest hook; null = no decision, Claude Code asks as usual. */
function approvalResponse(decision) {
  if (decision !== "allow" && decision !== "deny") return {};
  const d = decision === "allow" ? { behavior: "allow" }
    : { behavior: "deny", message: "The user denied this from the Clawd Buddy card." };
  return { hookSpecificOutput: { hookEventName: APPROVAL_EVENT, decision: d } };
}

/** Throws on invalid JSON so we never overwrite a file we couldn't parse. */
function read() {
  if (!fs.existsSync(SETTINGS)) return {};
  const text = fs.readFileSync(SETTINGS, "utf8");
  return text.trim() ? JSON.parse(text) : {};
}

function write(settings) {
  fs.mkdirSync(path.dirname(SETTINGS), { recursive: true });
  const tmp = SETTINGS + ".tmp-clawdbuddy";
  fs.writeFileSync(tmp, JSON.stringify(settings, null, 2) + "\n");
  fs.renameSync(tmp, SETTINGS);
}

/** Removes our entries, leaving everyone else's hooks alone. */
function strip(settings) {
  if (!settings.hooks) return;
  for (const event of Object.keys(settings.hooks)) {
    const groups = settings.hooks[event];
    if (!Array.isArray(groups)) continue;
    settings.hooks[event] = groups.flatMap((g) => {
      if (!hasOurs(g)) return [g];
      const rest = g.hooks.filter((h) => !isOurs(h));
      return rest.length ? [{ ...g, hooks: rest }] : [];
    });
    if (settings.hooks[event].length === 0) delete settings.hooks[event];
  }
  if (Object.keys(settings.hooks).length === 0) delete settings.hooks;
}

function status() {
  try {
    const s = read();
    const groups = (e) => (Array.isArray(s.hooks?.[e]) ? s.hooks[e] : []);
    const all = [...EVENTS, APPROVAL_EVENT];
    const installed = all.every((e) => groups(e).some((g) => hasCurrent(g, e)));
    const outdated = !installed && all.some((e) => groups(e).some(hasOurs));
    return { installed, outdated, error: false, path: SETTINGS };
  } catch {
    return { installed: false, outdated: false, error: true, path: SETTINGS };
  }
}

function install() {
  const s = read();
  if (!fs.existsSync(BACKUP) && fs.existsSync(SETTINGS)) fs.copyFileSync(SETTINGS, BACKUP);
  strip(s);
  s.hooks = s.hooks || {};
  const ours = { type: "http", url: hookUrl(), timeout: 2 };
  for (const e of EVENTS) {
    s.hooks[e] = s.hooks[e] || [];
    s.hooks[e].push(TOOL_EVENTS.has(e) ? { matcher: "*", hooks: [ours] } : { hooks: [ours] });
  }
  // Waits for the card (at most ~20 s); no answer means Claude Code asks as usual.
  s.hooks[APPROVAL_EVENT] = s.hooks[APPROVAL_EVENT] || [];
  s.hooks[APPROVAL_EVENT].push({ matcher: "*", hooks: [{ type: "http", url: approveUrl(), timeout: APPROVAL_TIMEOUT_S }] });
  write(s);
}

function uninstall() {
  const s = read();
  strip(s);
  write(s);
}

module.exports = {
  PORT, HOST, setToken, hookPath, approvePath, normalize, readBody, status, install, uninstall,
  approvalDetail, visible, approvalResponse,
};
