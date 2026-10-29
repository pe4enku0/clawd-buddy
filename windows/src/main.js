// Clawd Buddy for Windows (also runs on macOS/Linux for development).
const { app, BrowserWindow, Tray, Menu, ipcMain, screen, nativeImage, nativeTheme, globalShortcut, clipboard,
  desktopCapturer } = require("electron");
const fs = require("fs");
const http = require("http");
const path = require("path");
const { L10n } = require("./renderer/strings.js");
const hooks = require("./hooks");
const { Prefs } = require("./prefs");
const { Card } = require("./card");
const claude = require("./claude");
const files = require("./files");
const T = require("./timers");

const BASE = { w: 380, h: 136 };
const SCALE = { small: 2 / 3, medium: 1, large: 4 / 3 };
const ASSETS = path.join(__dirname, "..", "assets");
const isWin = process.platform === "win32";
const isMac = process.platform === "darwin";

let prefs, buddy, settingsWin, tray, server;
let drag = null;          // { cx, cy, wx, wy, moved }
let manuallyHidden = false;
let card;
let hotkeyOk = { chat: true, screen: true };
let capturing = false;  // the card hides for a screenshot; that blur mustn't close the chat
// The chat in the card: one conversation per opening, follow-ups carry it in the prompt.
// `file` is a dropped file this chat is about, kept for follow-ups and deleted when the chat closes.
// `screenshot` is the latest picture of the screen in this chat, kept for follow-ups like the file.
const chat = { open: false, phase: "input", question: "", answer: "", error: false, note: "", history: [], cancel: null,
  file: null, screenshot: null, attach: false, looking: false };
// The permission request on the card, if any: { res, title, detail, since, fits, timer }.
let approval = null;
const APPROVAL_CARD_MS = 20_000;
// Timers and the stopwatch; `alarm` is the one whose card is up, the queue holds any that rang meanwhile.
let timerStore, alarm = null, alarmQueue = [], lastBadge = "", lastTimerKey = "";

if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on("second-instance", () => openSettings());
  app.whenReady().then(start);
}

function start() {
  if (isWin) app.setAppUserModelId("com.clawdbuddy.app");
  if (isMac) app.dock?.hide();
  prefs = new Prefs(app.getPath("userData"));
  L10n.lang = prefs.get("lang");
  hooks.setToken(prefs.hookToken());
  // Hooks from a version without the token would be rejected now, so point them at the new URL.
  if (hooks.status().outdated) {
    try { hooks.install(); } catch (e) { console.error("hooks upgrade:", e.message); }
  }
  applyLoginItem();

  files.cleanUp();
  timerStore = new T.TimerStore(app.getPath("userData"));
  createBuddy();
  card = new Card({
    preload: path.join(__dirname, "preload.js"),
    buddyBounds: () => buddy.getBounds(),
    // A click anywhere else closes the chat, like a popover; an approval waits for its buttons.
    onBlur: () => { if (!approval && !alarm && !capturing) closeChat(); },
  });
  registerHotkeys();
  createTray();
  setInterval(timerTick, 250);
  startServer();
  setInterval(pollCursor, 33);
  screen.on("display-metrics-changed", placeBuddy);
  screen.on("display-removed", placeBuddy);
  nativeTheme.on("updated", updateTitleBarOverlay);
}

// MARK: Buddy window

const scale = () => SCALE[prefs.get("size")] || 1;
const buddySize = () => ({ width: Math.round(BASE.w * scale()), height: Math.round(BASE.h * scale()) });

function defaultAnchor() {
  const wa = screen.getPrimaryDisplay().workArea;
  return { x: wa.x + wa.width - 6, y: wa.y + 2 };
}

function anchorIsVisible(a) {
  const { width, height } = buddySize();
  return screen.getAllDisplays().some(({ workArea: w }) => {
    const ix = Math.min(a.x, w.x + w.width) - Math.max(a.x - width, w.x);
    const iy = Math.min(a.y + height, w.y + w.height) - Math.max(a.y, w.y);
    return ix > 100 && iy > 40;
  });
}

function placeBuddy() {
  if (!buddy) return;
  let a = prefs.get("anchor");
  if (!a || !anchorIsVisible(a)) {
    a = defaultAnchor();
    prefs.set("anchor", null);
  }
  const { width, height } = buddySize();
  buddy.setBounds({ x: Math.round(a.x - width), y: Math.round(a.y), width, height });
}

function createBuddy() {
  buddy = new BrowserWindow({
    ...buddySize(),
    transparent: true, frame: false, resizable: false, movable: false, minimizable: false, maximizable: false,
    fullscreenable: false, skipTaskbar: true, focusable: false, hasShadow: false, show: false,
    alwaysOnTop: true, backgroundColor: "#00000000",
    webPreferences: { preload: path.join(__dirname, "preload.js"), backgroundThrottling: false },
  });
  buddy.setAlwaysOnTop(true, "screen-saver");
  buddy.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
  buddy.setIgnoreMouseEvents(true, { forward: true });
  placeBuddy();
  buddy.loadFile(path.join(__dirname, "renderer", "buddy.html"));
  buddy.once("ready-to-show", () => buddy.showInactive());
}

function sendToBuddy(channel, ...args) {
  if (buddy && !buddy.isDestroyed()) buddy.webContents.send(channel, ...args);
}

function pollCursor() {
  if (!buddy || buddy.isDestroyed()) return;
  const p = screen.getCursorScreenPoint();
  if (drag) {
    const dx = p.x - drag.cx, dy = p.y - drag.cy;
    if (!drag.moved && Math.abs(dx) + Math.abs(dy) > 3) {
      drag.moved = true;
      sendToBuddy("drag-moved");
    }
    if (drag.moved) buddy.setPosition(Math.round(drag.wx + dx), Math.round(drag.wy + dy));
  }
  const b = buddy.getBounds(), s = scale();
  sendToBuddy("cursor", { x: (p.x - b.x) / s, y: (p.y - b.y) / s });
}

ipcMain.on("ready", (e) => {
  if (e.sender === buddy?.webContents) {
    sendToBuddy("prefs", prefs.public);
    const connected = hooks.status().installed;
    if (!prefs.get("firstRunDone")) {
      prefs.set("firstRunDone", true);
      openSettings();
    }
    sendToBuddy("command", connected ? "greet" : "remind");
  }
});

ipcMain.on("interactive", (e, on) => {
  if (e.sender === buddy?.webContents) buddy.setIgnoreMouseEvents(!on, { forward: true });
});

ipcMain.on("drag-start", () => {
  const p = screen.getCursorScreenPoint(), b = buddy.getBounds();
  drag = { cx: p.x, cy: p.y, wx: b.x, wy: b.y, moved: false };
});

ipcMain.handle("drag-end", () => {
  const moved = !!drag?.moved;
  drag = null;
  if (moved) {
    const b = buddy.getBounds();
    prefs.set("anchor", { x: b.x + b.width, y: b.y });
  }
  return moved;
});

ipcMain.on("show-menu", () => Menu.buildFromTemplate(menuTemplate()).popup({ window: buddy }));

// MARK: Prefs

function setPref(key, value) {
  if (!prefs.set(key, value)) return;
  if (key === "lang") L10n.lang = value;
  if (key === "size") {
    const b = buddy.getBounds(), { width, height } = buddySize();
    buddy.setBounds({ x: b.x + b.width - width, y: b.y, width, height });
    prefs.set("anchor", { x: b.x + b.width, y: b.y });
  }
  if (key === "launchAtLogin") applyLoginItem();
  if (key === "chatHotkey" || key === "screenHotkey") registerHotkeys();
  sendToBuddy("prefs", prefs.public);
  if (settingsWin && !settingsWin.isDestroyed()) settingsWin.webContents.send("prefs", prefs.public);
  refreshTray();
}

function applyLoginItem() {
  // Only the installed app should register itself, never the dev Electron binary.
  if (app.isPackaged && (isWin || isMac)) app.setLoginItemSettings({ openAtLogin: prefs.get("launchAtLogin") });
}

ipcMain.handle("get-state", () => ({
  prefs: prefs.public, hooks: hooks.status(), platform: process.platform, canLaunchAtLogin: isWin || isMac,
  version: app.getVersion(), hotkeyOk,
}));
ipcMain.handle("set-pref", (_e, key, value) => { setPref(key, value); return prefs.public; });
ipcMain.handle("demo", () => runCommand("demo"));

for (const [channel, action] of [["hooks-connect", hooks.install], ["hooks-disconnect", hooks.uninstall]]) {
  ipcMain.handle(channel, () => {
    try { action(); } catch (e) { return { ...hooks.status(), error: true, message: String(e.message || e) }; }
    const st = hooks.status();
    sendToBuddy("command", st.installed ? "greet" : "remind");
    return st;
  });
}

// MARK: Chat

function registerHotkeys() {
  globalShortcut.unregisterAll();
  const reg = (accel, fn) => { try { return globalShortcut.register(accel, fn); } catch { return false; } };
  hotkeyOk = { chat: reg(prefs.get("chatHotkey"), toggleChat), screen: reg(prefs.get("screenHotkey"), describeScreen) };
}

// The settings page is recording a new shortcut: the old one mustn't fire meanwhile.
ipcMain.handle("hotkey-recording", (_e, on) => {
  if (on) globalShortcut.unregisterAll(); else registerHotkeys();
  return hotkeyOk;
});

const chatState = () => ({
  view: "chat", phase: chat.phase, question: chat.question, answer: chat.answer, error: chat.error,
  note: chat.note, attach: chat.attach, looking: chat.looking, lang: prefs.get("lang"),
  timers: timerStore.timers.slice(0, 3).map((t) => ({ id: t.id, name: timerName(t), fireAt: t.fireAt })),
  stopwatch: timerStore.stopwatch,
});

/** What the card shows: a permission request first, then an alarm, then the chat. */
function cardState() {
  if (approval) return approvalState();
  if (alarm) return alarmState();
  if (chat.open) return chatState();
  return null;
}

function refreshCard({ focus = false } = {}) {
  const s = cardState();
  if (s) card.show(s, { focus }); else card.hide();
}

function pushChat() { if (chat.open && !approval && !alarm) card.send(chatState()); }

function openChat() {
  if (manuallyHidden) toggleVisible();
  if (!chat.open) {
    Object.assign(chat, { open: true, phase: "input", question: "", answer: "", error: false, note: "", history: [],
      attach: false, looking: false });
  }
  refreshCard({ focus: true });
}

function closeChat() {
  if (!chat.open) return;
  chat.cancel?.();
  chat.cancel = null;
  chat.open = false;
  files.discard(chat.file);
  files.discard(chat.screenshot && { path: chat.screenshot });
  chat.file = null;
  chat.screenshot = null;
  refreshCard();
}

/** "What's on my screen?" from the hotkey or the menu: opens the chat if needed. */
function describeScreen() {
  if (!chat.open) openChat();
  askChat(L10n.ui("screenQuestion"), null, true);
}

/** The screen under the cursor as a downscaled JPEG, with the card out of the way. */
async function grabScreen() {
  const d = screen.getDisplayNearestPoint(screen.getCursorScreenPoint());
  capturing = true;
  card.hide();
  try {
    await new Promise((r) => setTimeout(r, 180));
    const size = { width: Math.round(d.size.width * d.scaleFactor), height: Math.round(d.size.height * d.scaleFactor) };
    const sources = await desktopCapturer.getSources({ types: ["screen"], thumbnailSize: size });
    const src = sources.find((s) => s.display_id === String(d.id)) || sources[0];
    if (!src || src.thumbnail.isEmpty()) return null;
    let img = src.thumbnail;
    const { width, height } = img.getSize(), k = Math.min(1, 1600 / Math.max(width, height));
    if (k < 1) img = img.resize({ width: Math.round(width * k), height: Math.round(height * k), quality: "good" });
    return files.saveScreenshot(img.toJPEG(80));
  } catch {
    return null;
  } finally {
    capturing = false;
  }
}

function toggleChat() {
  if (chat.open) closeChat(); else openChat();
}

/** The CLI call is stateless, so earlier turns of this chat ride along in the prompt. */
function chatPrompt(question) {
  if (!chat.history.length) return question;
  const past = chat.history.map((t) => `User: ${t.question}\nClawd: ${t.answer}`).join("\n\n");
  return `Earlier in this chat:\n\n${past}\n\n---\nThe user's new message:\n${question}`;
}

function chatError(error) {
  switch (error.kind) {
    case "notFound": return L10n.ui("errNotFound");
    case "notLoggedIn": return L10n.ui("errLogin");
    case "offline": return L10n.ui("errOffline");
    case "timeout": return L10n.ui("errTimeout");
    default: return L10n.ui("errOther") + (error.detail || "");
  }
}

/**
 * `prompt` replaces the usual one (the file summary request). A screenshot goes along when asked
 * for: the hotkey, the button by the field, or a message that mentions the screen.
 */
async function askChat(question, prompt = null, withScreen = false) {
  if (!chat.open || chat.phase === "thinking") return;
  const wantsScreen = !prompt && (withScreen || chat.attach || files.mentionsScreen(question));
  if (!prompt) chat.note = "";
  Object.assign(chat, { question, answer: "", error: false, phase: "thinking", attach: false, looking: wantsScreen });
  pushChat();
  // Timer and stopwatch commands are handled right here; only phrasing we can't read goes to Claude.
  if (!prompt && !withScreen) {
    const sw = T.parseStopwatch(question);
    if (sw) { reply(stopwatchCommand(sw)); return; }
    const cmd = T.parse(question);
    if (cmd) { handleTimer(cmd, question); return; }
  }
  if (wantsScreen) {
    const shot = await grabScreen();
    refreshCard({ focus: true });
    if (!chat.open) { files.discard(shot && { path: shot }); return; }
    if (!shot) {
      Object.assign(chat, { answer: L10n.ui("screenFailed"), error: true, phase: "answer" });
      pushChat();
      return;
    }
    files.discard(chat.screenshot && { path: chat.screenshot });
    chat.screenshot = shot;
  }
  let text = prompt || chatPrompt(question);
  const attached = [];
  if (chat.file) {
    attached.push(chat.file.path);
    if (!prompt) {
      text = `Earlier the user dropped the file ${chat.file.name} into this chat; it is in the current folder. `
        + `Read it again if the question needs it.${chat.file.hint}\n\n${text}`;
    }
  }
  if (chat.screenshot) {
    attached.push(chat.screenshot);
    text = `The user attached a screenshot of their screen: ${path.basename(chat.screenshot)} in the current folder. `
      + "Read it before answering. If they only ask what's on screen, describe it in 2-4 sentences: "
      + `which app, what they're doing, and any error or problem you can see.\n\n${text}`;
  }
  chat.cancel = claude.ask(text, {
    files: attached,
    onText: (text) => { Object.assign(chat, { answer: text, phase: "answer" }); pushChat(); },
    onDone: (r) => {
      chat.cancel = null;
      if (r.ok) {
        chat.answer = r.text;
        chat.history.push({ question, answer: r.text });
      } else {
        Object.assign(chat, { answer: chatError(r.error), error: true });
      }
      chat.phase = "answer";
      pushChat();
    },
  });
}

// MARK: Files

/** Electron's own image code shrinks pictures before they're sent. */
function resizeImage(file, maxPixels) {
  const img = nativeImage.createFromPath(file);
  if (img.isEmpty()) return null;
  const { width, height } = img.getSize();
  const k = Math.min(1, maxPixels / Math.max(width, height));
  return (k < 1 ? img.resize({ width: Math.round(width * k), height: Math.round(height * k), quality: "good" }) : img).toJPEG(85);
}

/** A file landed on the crab or the card: sum it up in the chat, then keep it for follow-ups. */
function dropFile(file) {
  if (!chat.open) openChat();
  chat.cancel?.();
  chat.cancel = null;
  files.discard(chat.file);
  files.discard(chat.screenshot && { path: chat.screenshot });
  Object.assign(chat, { file: null, screenshot: null, history: [], phase: "input" });
  const lang = prefs.get("lang");
  const prepared = files.prepare(file, { lang, resizeImage });
  if (!prepared) {
    Object.assign(chat, { question: path.basename(file), answer: L10n.ui("fileUnsupported"), error: true, note: "", phase: "answer" });
    refreshCard({ focus: true });
    return;
  }
  chat.file = prepared;
  chat.note = prepared.note || "";
  const prompt = `The user dropped a file on you: ${prepared.name}, in the current folder. Read it and sum it up `
    + `in 3-5 sentences: what it is and its main points.${prepared.hint} Reply in ${lang === "ru" ? "Russian" : "English"}.`;
  askChat(L10n.ui("fileSummary").replace("%s", prepared.name), prompt);
  refreshCard({ focus: true });
}

ipcMain.on("file-dropped", (e, file) => {
  const ok = e.sender === buddy?.webContents || e.sender === card?.webContents;
  if (ok && typeof file === "string" && path.isAbsolute(file) && fs.existsSync(file)) dropFile(file);
});

const fromCard = (e) => e.sender === card?.webContents;
ipcMain.on("card-submit", (e, text) => { if (fromCard(e) && typeof text === "string") askChat(text.slice(0, 4000)); });
ipcMain.on("card-close", (e) => { if (fromCard(e)) closeChat(); });
ipcMain.on("card-height", (e, h) => { if (fromCard(e) && Number.isFinite(h)) card.setHeight(h); });
ipcMain.on("card-copy", (e, text) => { if (fromCard(e) && typeof text === "string") clipboard.writeText(text); });
ipcMain.on("card-attach", (e) => { if (fromCard(e) && chat.open) { chat.attach = !chat.attach; pushChat(); } });

// MARK: Timers

const lang = () => prefs.get("lang");
const fmt = (key, vals) => L10n.ui(key).replace(/%([sdtne])/g, (_m, k) => vals[k] ?? "");

function timerName(t) {
  if (t.label) return t.label;
  return t.duration ? fmt("timerNamed", { d: T.length(t.duration, lang()) }) : L10n.ui("alarmNamed");
}

/** An answer we wrote ourselves, shown like Claude's. */
function reply(text) {
  Object.assign(chat, { answer: text, error: false, phase: "answer" });
  chat.history.push({ question: chat.question, answer: text });
  pushChat();
}

function setTimer(fireAt, label, duration) {
  timerStore.add(fireAt, label, duration);
  const t = T.clock(fireAt, lang());
  reply(label ? fmt("timerSetLabel", { s: label, t }) : fmt("timerSetPlain", { d: T.length(duration || 0, lang()), t }));
}

function handleTimer(cmd, question) {
  if (cmd.type === "set") { setTimer(cmd.fireAt, cmd.label, cmd.duration); return; }
  if (cmd.type === "cancel") {
    const gone = cmd.all ? [...timerStore.timers] : timerStore.timers.slice(0, 1);
    if (!gone.length) { reply(L10n.ui("noTimers")); return; }
    gone.forEach((t) => timerStore.remove(t.id));
    reply(gone.length === 1 ? fmt("cancelledOne", { s: timerName(gone[0]) }) : fmt("cancelledAll", { n: gone.length }));
    return;
  }
  if (cmd.type === "list") {
    const now = Date.now();
    reply(timerStore.timers.length
      ? [L10n.ui("running"), ...timerStore.timers.map((t) => `• ${timerName(t)}: ${T.left((t.fireAt - now) / 1000)} (${T.clock(t.fireAt, lang())})`)].join("\n")
      : L10n.ui("noTimers"));
    return;
  }
  // needsHelp: a TIMER line from Claude becomes a timer; anything else is just its answer.
  chat.cancel = claude.ask(T.helpPrompt(question), {
    onDone: (r) => {
      chat.cancel = null;
      if (!chat.open) return;
      if (!r.ok) { Object.assign(chat, { answer: chatError(r.error), error: true, phase: "answer" }); pushChat(); return; }
      const t = T.parseHelp(r.text);
      if (t) setTimer(t.fireAt, t.label, null); else reply(r.text);
    },
  });
}

/** Runs a stopwatch command (chat or card buttons) and says what happened. */
function stopwatchCommand(cmd) {
  const now = Date.now(), sw = timerStore.stopwatch, e = () => T.elapsed(timerStore.stopwatchElapsed(now));
  if (cmd === "start" && !sw) { timerStore.setStopwatch({ accumulated: 0, startedAt: now }); return L10n.ui("stopwatchStarted"); }
  if ((cmd === "start" || cmd === "resume") && sw && !sw.startedAt) {
    timerStore.setStopwatch({ ...sw, startedAt: now });
    return fmt("swResume", { e: e() });
  }
  if (cmd === "pause" && sw?.startedAt) {
    const text = fmt("swPause", { e: e() });
    timerStore.setStopwatch({ accumulated: timerStore.stopwatchElapsed(now), startedAt: null });
    return text;
  }
  if (cmd === "reset" && sw) { const text = fmt("swReset", { e: e() }); timerStore.setStopwatch(null); return text; }
  return sw && cmd !== "reset" ? fmt("swShow", { e: e() }) : L10n.ui("stopwatchNotRunning");
}

const alarmState = () => ({
  view: "alarm", lang: lang(), since: alarm.shownAt, sound: prefs.get("timerSound"),
  title: "⏰ " + (alarm.label || L10n.ui("timeIsUp")),
  subtitle: Date.now() - alarm.fireAt > 60_000 ? fmt("missedAt", { t: T.clock(alarm.fireAt, lang()) })
    : alarm.duration ? timerName({ duration: alarm.duration }) : T.clock(alarm.fireAt, lang()),
});

function answerAlarm(snooze) {
  if (!alarm || Date.now() - alarm.shownAt < 500) return;
  if (snooze) timerStore.add(new Date(Date.now() + 300_000), alarm.label, 300);
  alarm = null;
  refreshCard();
}

/** Rings due timers one card at a time, keeps the badge under the crab and the card's list fresh. */
function timerTick() {
  const due = timerStore.popDue();
  if (due.length) alarmQueue.push(...due);
  if (!alarm && alarmQueue.length && !approval) {
    alarm = { ...alarmQueue.shift(), shownAt: Date.now() };
    if (manuallyHidden) toggleVisible();
    sendToBuddy("command", "alarm");
    refreshCard();
  }

  const now = Date.now(), next = timerStore.timers[0], sw = timerStore.stopwatch;
  const badge = next ? { text: `⏱ ${T.compact((next.fireAt - now) / 1000, lang())}`, kind: "timer" }
    : sw?.startedAt ? { text: T.elapsed(timerStore.stopwatchElapsed(now)), kind: "stopwatch" } : null;
  const key = JSON.stringify(badge);
  if (key !== lastBadge) { lastBadge = key; sendToBuddy("badge", badge); }

  const timerKey = JSON.stringify([timerStore.timers.map((t) => t.id), sw]);
  if (timerKey !== lastTimerKey) { lastTimerKey = timerKey; pushChat(); }
}

ipcMain.on("timer-cancel", (e, id) => { if (fromCard(e)) { timerStore.remove(id); pushChat(); } });
ipcMain.on("stopwatch", (e, cmd) => {
  if (fromCard(e) && ["pause", "resume", "reset"].includes(cmd)) { stopwatchCommand(cmd); pushChat(); }
});
ipcMain.on("alarm-answer", (e, snooze) => { if (fromCard(e)) answerAlarm(snooze === true); });

// MARK: Approvals

function approvalTitle(tool) {
  switch (tool) {
    case "Bash": case "PowerShell": return L10n.ui("approveCommand");
    case "Edit": case "MultiEdit": case "Write": case "NotebookEdit": return L10n.ui("approveEdit");
    case "WebFetch": case "WebSearch": return L10n.ui("approveWeb");
    default: return L10n.ui("approveTool").replace("%s", tool.startsWith("mcp__") ? tool.split("__").pop() : tool);
  }
}

const approvalState = () => ({
  view: "approval", title: approval.title, detail: approval.detail, since: approval.since,
  seconds: APPROVAL_CARD_MS / 1000, lang: prefs.get("lang"),
});

/** A PermissionRequest hook is waiting on `res` until the user answers or the card times out. */
function requestApproval(payload, res) {
  // One card at a time, and only when wanted; everything else goes to the terminal at once.
  if (approval || !prefs.get("approvalCard")) { respondApproval(res, null); return; }
  const tool = typeof payload.tool_name === "string" ? payload.tool_name : "";
  approval = {
    res, since: Date.now(), fits: false,
    title: hooks.visible(approvalTitle(tool)),
    detail: hooks.visible(hooks.approvalDetail(tool, payload.tool_input || {})),
    timer: setTimeout(() => answerApproval("terminal"), APPROVAL_CARD_MS),
  };
  // Claude Code got its answer elsewhere (terminal, editor) or gave up: drop the card.
  res.on("close", () => { if (approval?.res === res && !res.writableEnded) closeApproval(); });
  sendToBuddy("hook", { event: "Notification", kind: "permission_prompt", tool: "", detail: "", message: "" });
  refreshCard();
}

function respondApproval(res, decision) {
  if (res.writableEnded) return;
  res.writeHead(200, { "Content-Type": "application/json" }).end(JSON.stringify(hooks.approvalResponse(decision)));
}

/** Nothing is allowed unless the user clicked Allow on a card that showed the whole request. */
function answerApproval(decision) {
  if (!approval) return;
  if (decision !== "terminal" && Date.now() - approval.since < 700) return;  // a stray click as it appeared
  if (decision === "allow" && !approval.fits) return;
  respondApproval(approval.res, decision);
  closeApproval();
  if (decision !== "terminal") sendToBuddy("command", "answered");
}

function closeApproval() {
  if (!approval) return;
  clearTimeout(approval.timer);
  approval = null;
  refreshCard();
}

ipcMain.on("approval-answer", (e, d) => { if (fromCard(e) && ["allow", "deny", "terminal"].includes(d)) answerApproval(d); });
ipcMain.on("approval-fits", (e, fits) => { if (fromCard(e) && approval) approval.fits = fits === true; });

// MARK: Hook server

function startServer() {
  server = http.createServer((req, res) => {
    // Claude Code sends neither Origin nor a foreign Host; browsers (incl. DNS rebinding) do.
    const isApproval = req.url === hooks.approvePath();
    if (req.method !== "POST" || (req.url !== hooks.hookPath() && !isApproval)
        || req.headers.host !== hooks.HOST || req.headers.origin) {
      res.writeHead(404).end();
      return;
    }
    if (isApproval) {
      hooks.readBody(req).then((body) => {
        let payload;
        try { payload = JSON.parse(body); } catch { respondApproval(res, null); return; }
        requestApproval(payload, res);
      }).catch(() => { if (!res.writableEnded) res.writeHead(413).end(); });
      return;
    }
    hooks.readBody(req).then((body) => {
      // Answer right away so Claude Code never waits on us.
      res.writeHead(200, { "Content-Type": "application/json" }).end("{}");
      try {
        const info = hooks.normalize(JSON.parse(body));
        // The turn moved on without the card: let the terminal have it.
        if (info.event === "Stop" || info.event === "UserPromptSubmit") answerApproval("terminal");
        sendToBuddy("hook", info);
      } catch {}
    }).catch(() => {
      if (!res.writableEnded) res.writeHead(413).end();
    });
  });
  server.on("error", (e) => console.error("hook server:", e.message));
  server.listen(hooks.PORT, "127.0.0.1");
}

// MARK: Tray & menu

function runCommand(cmd) {
  if (manuallyHidden) toggleVisible();
  sendToBuddy("command", cmd);
}

function toggleVisible() {
  manuallyHidden = !manuallyHidden;
  if (manuallyHidden) buddy.hide(); else buddy.showInactive();
  refreshTray();
}

function menuTemplate() {
  const lang = prefs.get("lang");
  return [
    { label: "Clawd Buddy", enabled: false },
    { type: "separator" },
    { label: L10n.ui("askClawd"), accelerator: prefs.get("chatHotkey"), click: openChat },
    { label: L10n.ui("whatsOnScreen"), accelerator: prefs.get("screenHotkey"), click: describeScreen },
    { label: L10n.ui("settings"), click: openSettings },
    {
      label: L10n.ui("language"),
      submenu: [["en", "English"], ["ru", "Русский"]].map(([code, name]) => ({
        label: name, type: "radio", checked: lang === code,
        click: () => { setPref("lang", code); runCommand("greet"); },
      })),
    },
    {
      label: L10n.ui("hideWhenSleeping"), type: "checkbox", checked: prefs.get("hideWhenSleeping"),
      click: () => setPref("hideWhenSleeping", !prefs.get("hideWhenSleeping")),
    },
    { type: "separator" },
    { label: L10n.ui("sayHi"), click: () => runCommand("greet") },
    { label: L10n.ui("playDemo"), click: () => runCommand("demo") },
    { label: L10n.ui(manuallyHidden ? "show" : "hide"), click: toggleVisible },
    { label: L10n.ui("resetPosition"), click: () => { prefs.set("anchor", null); placeBuddy(); } },
    { type: "separator" },
    { label: L10n.ui("quit"), click: () => app.quit() },
  ];
}

function createTray() {
  let icon;
  if (isMac) {
    icon = nativeImage.createFromPath(path.join(ASSETS, "trayTemplate.png"));
    icon.setTemplateImage(true);
  } else {
    icon = nativeImage.createFromPath(path.join(ASSETS, "tray.png"));
  }
  tray = new Tray(icon);
  tray.setToolTip("Clawd Buddy");
  tray.on("click", () => tray.popUpContextMenu());
  refreshTray();
}

function refreshTray() {
  if (tray) tray.setContextMenu(Menu.buildFromTemplate(menuTemplate()));
}

// MARK: Settings window

const themeColors = () => (nativeTheme.shouldUseDarkColors
  ? { color: "#262624", symbolColor: "#F5F4EF" }
  : { color: "#F5F4EE", symbolColor: "#141413" });

function updateTitleBarOverlay() {
  if (isWin && settingsWin && !settingsWin.isDestroyed()) settingsWin.setTitleBarOverlay({ ...themeColors(), height: 36 });
  if (settingsWin && !settingsWin.isDestroyed()) settingsWin.setBackgroundColor(themeColors().color);
}

function openSettings() {
  if (settingsWin && !settingsWin.isDestroyed()) {
    settingsWin.show();
    settingsWin.focus();
    return;
  }
  settingsWin = new BrowserWindow({
    width: 460, height: 820, useContentSize: true, resizable: false, maximizable: false, fullscreenable: false,
    show: false, title: "Clawd Buddy", icon: path.join(ASSETS, "icon.png"),
    backgroundColor: themeColors().color,
    titleBarStyle: "hidden",
    ...(isWin ? { titleBarOverlay: { ...themeColors(), height: 36 } } : {}),
    webPreferences: { preload: path.join(__dirname, "preload.js") },
  });
  settingsWin.setMenu(null);
  settingsWin.loadFile(path.join(__dirname, "renderer", "settings.html"));
  settingsWin.once("ready-to-show", () => settingsWin.show());
  settingsWin.on("focus", () => settingsWin.webContents.send("hooks-status", hooks.status()));
}

ipcMain.on("settings-height", (e, h) => {
  if (!settingsWin || e.sender !== settingsWin.webContents) return;
  // Small laptop screens: cap to the work area and let the page scroll.
  const max = screen.getDisplayMatching(settingsWin.getBounds()).workArea.height - 40;
  settingsWin.setContentSize(460, Math.min(Math.ceil(h), max));
});

app.on("window-all-closed", (e) => e.preventDefault());
app.on("before-quit", () => server?.close());
app.on("will-quit", () => globalShortcut.unregisterAll());
