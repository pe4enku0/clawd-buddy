// Settings page: renders from main-process state, writes every change straight back.
(function () {
  let state = null;
  const $ = (id) => document.getElementById(id);

  function render() {
    const { prefs, hooks } = state;
    L10n.lang = prefs.lang;
    document.documentElement.lang = prefs.lang;
    for (const el of document.querySelectorAll("[data-i18n]")) el.textContent = L10n.ui(el.dataset.i18n);
    // app.getVersion() is the single source of truth; the phrase table has no version in it.
    document.querySelector("footer").textContent = `${L10n.ui("footer")} · v${state.version}`;

    for (const seg of document.querySelectorAll(".seg")) {
      for (const b of seg.children) b.classList.toggle("on", b.dataset.value === prefs[seg.dataset.pref]);
    }
    for (const sw of document.querySelectorAll(".switch")) sw.checked = !!prefs[sw.dataset.pref];

    const pct = Math.round(prefs.chattiness * 100);
    $("chattiness").value = pct;
    $("chattiness").style.setProperty("--fill", `${pct}%`);
    $("chattinessValue").textContent = `${pct}%`;
    $("loginRow").hidden = !state.canLaunchAtLogin;
    if (!recording) $("chatHotkey").textContent = prettyHotkey(prefs.chatHotkey);
    $("hotkeyHint").textContent = L10n.ui(state.hotkeyOk === false ? "hotkeyTaken" : "chatHotkeyHint");
    $("hotkeyHint").classList.toggle("warn", state.hotkeyOk === false);

    $("hooksDot").classList.toggle("ok", hooks.installed);
    $("hooksText").textContent = L10n.ui(hooks.installed ? "hooksOn" : "hooksOff");
    $("hooksHint").textContent = hooks.error ? L10n.ui("hooksError") : hooks.installed ? "" : L10n.ui("hooksHint");
    $("hooksButton").textContent = L10n.ui(hooks.installed ? "disconnect" : "connect");

    requestAnimationFrame(() => clawd.send("settings-height", document.documentElement.scrollHeight));
  }

  // MARK: Shortcut recorder

  let recording = false;
  const mac = navigator.platform.startsWith("Mac");
  const prettyHotkey = (a) => (a || "").split("+")
    .map((k) => ({ Control: "Ctrl", Super: mac ? "⌘" : "Win", Alt: mac ? "⌥" : "Alt" })[k] || k).join("+");

  /** Electron accelerator from a key press, or null if it isn't a usable shortcut. */
  function accelerator(e) {
    const mods = [e.ctrlKey && "Control", e.altKey && "Alt", e.shiftKey && "Shift", e.metaKey && "Super"].filter(Boolean);
    if (!mods.some((m) => m !== "Shift")) return null;
    const m = e.code.match(/^Key([A-Z])$|^Digit([0-9])$|^(F[0-9]{1,2})$|^Arrow(Up|Down|Left|Right)$|^(Space)$/);
    if (!m) return null;
    return [...mods, m.slice(1).find(Boolean)].join("+");
  }

  async function stopRecording(value) {
    recording = false;
    window.removeEventListener("keydown", onRecordKey, true);
    if (value) state.prefs = await clawd.invoke("set-pref", "chatHotkey", value);
    state.hotkeyOk = await clawd.invoke("hotkey-recording", false);
    render();
  }

  function onRecordKey(e) {
    e.preventDefault();
    e.stopPropagation();
    if (e.key === "Escape") { stopRecording(null); return; }
    if (["Control", "Alt", "Shift", "Meta"].includes(e.key)) return;
    stopRecording(accelerator(e));
  }

  $("chatHotkey").addEventListener("click", async () => {
    if (recording) { stopRecording(null); return; }
    recording = true;
    await clawd.invoke("hotkey-recording", true);
    $("chatHotkey").textContent = L10n.ui("pressKeys");
    window.addEventListener("keydown", onRecordKey, true);
  });

  async function setPref(key, value) {
    state.prefs = await clawd.invoke("set-pref", key, value);
    render();
  }

  for (const seg of document.querySelectorAll(".seg")) {
    seg.addEventListener("click", (e) => {
      const b = e.target.closest("button");
      if (b) setPref(seg.dataset.pref, b.dataset.value);
    });
  }
  for (const sw of document.querySelectorAll(".switch")) {
    sw.addEventListener("change", () => setPref(sw.dataset.pref, sw.checked));
  }
  $("chattiness").addEventListener("input", (e) => {
    const pct = Number(e.target.value);
    e.target.style.setProperty("--fill", `${pct}%`);
    $("chattinessValue").textContent = `${pct}%`;
  });
  $("chattiness").addEventListener("change", (e) => setPref("chattiness", Number(e.target.value) / 100));

  $("hooksButton").addEventListener("click", async () => {
    state.hooks = await clawd.invoke(state.hooks.installed ? "hooks-disconnect" : "hooks-connect");
    render();
  });
  $("demo").addEventListener("click", () => clawd.invoke("demo"));

  clawd.on("prefs", (p) => { if (state) { state.prefs = p; render(); } });
  clawd.on("hooks-status", (h) => { if (state) { state.hooks = h; render(); } });

  BuddyView.drawStatic($("avatar"), 4, true);
  clawd.invoke("get-state").then((s) => { state = s; render(); });
})();
