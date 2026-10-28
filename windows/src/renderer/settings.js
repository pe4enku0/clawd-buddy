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

    $("hooksDot").classList.toggle("ok", hooks.installed);
    $("hooksText").textContent = L10n.ui(hooks.installed ? "hooksOn" : "hooksOff");
    $("hooksHint").textContent = hooks.error ? L10n.ui("hooksError") : hooks.installed ? "" : L10n.ui("hooksHint");
    $("hooksButton").textContent = L10n.ui(hooks.installed ? "disconnect" : "connect");

    requestAnimationFrame(() => clawd.send("settings-height", document.documentElement.scrollHeight));
  }

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
