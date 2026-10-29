// Clawd Buddy for Windows (also runs on macOS/Linux for development).
const { app, BrowserWindow, Tray, Menu, ipcMain, screen, nativeImage, nativeTheme, globalShortcut, clipboard } = require("electron");
const http = require("http");
const path = require("path");
const { L10n } = require("./renderer/strings.js");
const hooks = require("./hooks");
const { Prefs } = require("./prefs");
const { Card } = require("./card");
const claude = require("./claude");

const BASE = { w: 380, h: 136 };
const SCALE = { small: 2 / 3, medium: 1, large: 4 / 3 };
const ASSETS = path.join(__dirname, "..", "assets");
const isWin = process.platform === "win32";
const isMac = process.platform === "darwin";

let prefs, buddy, settingsWin, tray, server;
let drag = null;          // { cx, cy, wx, wy, moved }
let manuallyHidden = false;
let card;
let hotkeyOk = true;
// The chat in the card: one conversation per opening, follow-ups carry it in the prompt.
const chat = { open: false, phase: "input", question: "", answer: "", error: false, history: [], cancel: null };

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

  createBuddy();
  card = new Card({
    preload: path.join(__dirname, "preload.js"),
    buddyBounds: () => buddy.getBounds(),
    onBlur: closeChat,  // a click anywhere else closes it, like a popover
  });
  registerHotkeys();
  createTray();
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
  if (key === "chatHotkey") registerHotkeys();
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
  try { hotkeyOk = globalShortcut.register(prefs.get("chatHotkey"), toggleChat); } catch { hotkeyOk = false; }
}

// The settings page is recording a new shortcut: the old one mustn't fire meanwhile.
ipcMain.handle("hotkey-recording", (_e, on) => {
  if (on) globalShortcut.unregisterAll(); else registerHotkeys();
  return hotkeyOk;
});

const chatState = () => ({
  view: "chat", phase: chat.phase, question: chat.question, answer: chat.answer, error: chat.error,
  lang: prefs.get("lang"),
});

function pushChat() { if (chat.open) card.send(chatState()); }

function openChat() {
  if (manuallyHidden) toggleVisible();
  if (!chat.open) Object.assign(chat, { open: true, phase: "input", question: "", answer: "", error: false, history: [] });
  card.show(chatState(), { focus: true });
}

function closeChat() {
  if (!chat.open) return;
  chat.cancel?.();
  chat.cancel = null;
  chat.open = false;
  card.hide();
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

function askChat(question) {
  if (!chat.open || chat.phase === "thinking") return;
  Object.assign(chat, { question, answer: "", error: false, phase: "thinking" });
  pushChat();
  chat.cancel = claude.ask(chatPrompt(question), {
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

const fromCard = (e) => e.sender === card?.webContents;
ipcMain.on("card-submit", (e, text) => { if (fromCard(e) && typeof text === "string") askChat(text.slice(0, 4000)); });
ipcMain.on("card-close", (e) => { if (fromCard(e)) closeChat(); });
ipcMain.on("card-height", (e, h) => { if (fromCard(e) && Number.isFinite(h)) card.setHeight(h); });
ipcMain.on("card-copy", (e, text) => { if (fromCard(e) && typeof text === "string") clipboard.writeText(text); });

// MARK: Hook server

function startServer() {
  server = http.createServer((req, res) => {
    // Claude Code sends neither Origin nor a foreign Host; browsers (incl. DNS rebinding) do.
    if (req.method !== "POST" || req.url !== hooks.hookPath() || req.headers.host !== hooks.HOST || req.headers.origin) {
      res.writeHead(404).end();
      return;
    }
    hooks.readBody(req).then((body) => {
      // Answer right away so Claude Code never waits on us.
      res.writeHead(200, { "Content-Type": "application/json" }).end("{}");
      try { sendToBuddy("hook", hooks.normalize(JSON.parse(body))); } catch {}
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
