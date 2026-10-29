// The card next to the crab. Renders whatever the main process sends; model text only ever goes
// in as text nodes, so an answer can't inject markup or links.
(function () {
  const $ = (id) => document.getElementById(id);
  const card = $("card"), answer = $("answer"), input = $("input"), copy = $("copy");
  let state = null;

  BuddyView.drawStatic($("crab"), 1.5, false);

  /** ``` fences become code blocks (an unclosed one, still streaming, runs to the end). */
  function blocks(text) {
    return text.split("```").map((part, i) => {
      let t = part;
      if (i % 2 === 1) {
        const nl = t.indexOf("\n");
        if (nl >= 0 && !t.slice(0, nl).includes(" ")) t = t.slice(nl + 1);  // drop the language tag
      }
      return { code: i % 2 === 1, text: t.replace(/^\n+|\n+$/g, "") };
    }).filter((b) => b.text);
  }

  function renderAnswer(text, isError) {
    answer.replaceChildren();
    answer.classList.toggle("error", !!isError);
    for (const b of blocks(text)) {
      if (b.code) {
        const pre = document.createElement("pre");
        pre.textContent = b.text;
        answer.append(pre);
        continue;
      }
      const p = document.createElement("p");
      b.text.split("`").forEach((piece, i) => {
        if (!piece) return;
        if (i % 2 === 1) {
          const c = document.createElement("code");
          c.textContent = piece;
          p.append(c);
        } else {
          p.append(document.createTextNode(piece));
        }
      });
      answer.append(p);
    }
  }

  /** Approval: the whole request, a countdown ring, Deny / Allow. Allow only if it all fits. */
  function renderApproval() {
    $("title").textContent = state.title;
    $("subtitle").textContent = "";
    answer.replaceChildren();
    copy.classList.remove("ready");
    $("ask").hidden = true;
    $("approval").hidden = false;
    $("note").hidden = true;
    $("ring").hidden = false;
    $("ring").title = L10n.ui("answerInTerminal");
    $("deny").textContent = L10n.ui("deny");
    $("allow").textContent = L10n.ui("allow");
    const command = $("command");
    command.textContent = state.detail;
    const fits = command.scrollHeight <= command.clientHeight + 1;
    $("allow").disabled = !fits;
    $("tooLong").hidden = fits;
    $("tooLong").textContent = "⚠ " + L10n.ui("approvalTooLong");
    clawd.send("approval-fits", fits);

    // The ring empties over what's left of the card's time.
    const total = state.seconds, left = Math.max(0, total - (Date.now() - state.since) / 1000);
    const ring = $("ringLeft");
    ring.style.animation = "none";
    void ring.getBoundingClientRect();
    ring.style.setProperty("--from", String(69.1 * (1 - left / total)));
    ring.style.animation = `ring ${left}s linear forwards`;
    requestAnimationFrame(() => clawd.send("card-height", card.getBoundingClientRect().height));
  }

  $("allow").addEventListener("click", () => clawd.send("approval-answer", "allow"));
  $("deny").addEventListener("click", () => clawd.send("approval-answer", "deny"));
  $("ring").addEventListener("click", () => clawd.send("approval-answer", "terminal"));

  // MARK: Timers and the stopwatch

  const pad = (n) => String(n).padStart(2, "0");
  const left = (s) => { s = Math.max(0, Math.ceil(s)); return s >= 3600 ? `${Math.floor(s / 3600)}:${pad(Math.floor(s / 60) % 60)}:${pad(s % 60)}` : `${Math.floor(s / 60)}:${pad(s % 60)}`; };
  const elapsed = (t) => {
    const v = Math.max(0, t), s = Math.floor(v);
    const base = s >= 3600 ? `${Math.floor(s / 3600)}:${pad(Math.floor(s / 60) % 60)}:${pad(s % 60)}` : `${Math.floor(s / 60)}:${pad(s % 60)}`;
    return `${base}.${Math.floor(v * 10) % 10}`;
  };
  const swElapsed = (sw) => sw.accumulated + (sw.startedAt ? (Date.now() - sw.startedAt) / 1000 : 0);

  function clockRow(icon, name, timeFn, buttons) {
    const row = document.createElement("div");
    row.className = "clock";
    const i = document.createElement("span"), n = document.createElement("span"), t = document.createElement("span");
    i.className = "icon"; i.textContent = icon;
    n.className = "name"; n.textContent = name;
    t.className = "time"; t.textContent = timeFn();
    t.dataset.live = "1";
    t._update = timeFn;
    row.append(i, n, t);
    for (const [label, title, fn] of buttons) {
      const b = document.createElement("button");
      b.textContent = label; b.title = title; b.type = "button";
      b.addEventListener("click", fn);
      row.append(b);
    }
    return row;
  }

  function renderClocks(show) {
    const box = $("clocks");
    box.replaceChildren();
    const timers = (show && state.timers) || [], sw = show ? state.stopwatch : null;
    for (const t of timers) {
      box.append(clockRow("⏱", t.name, () => left((t.fireAt - Date.now()) / 1000),
        [["✕", "", () => clawd.send("timer-cancel", t.id)]]));
    }
    if (sw) {
      box.append(clockRow("◷", L10n.ui("stopwatch"), () => elapsed(swElapsed(sw)), [
        [sw.startedAt ? "❚❚" : "▶", "", () => clawd.send("stopwatch", sw.startedAt ? "pause" : "resume")],
        ["✕", "", () => clawd.send("stopwatch", "reset")],
      ]));
    }
    box.hidden = !box.children.length;
  }
  setInterval(() => { for (const t of document.querySelectorAll("[data-live]")) t.textContent = t._update(); }, 100);

  /** Three soft chimes, made right here (no sound files to ship). */
  let chimedFor = 0;
  function chime() {
    try {
      const ac = new AudioContext();
      for (let i = 0; i < 3; i++) {
        for (const [freq, delay] of [[880, 0], [1318.5, 0.16]]) {
          const o = ac.createOscillator(), g = ac.createGain(), at = ac.currentTime + i * 1.4 + delay;
          o.type = "sine"; o.frequency.value = freq;
          g.gain.setValueAtTime(0, at);
          g.gain.linearRampToValueAtTime(0.18, at + 0.02);
          g.gain.exponentialRampToValueAtTime(0.0001, at + 0.9);
          o.connect(g).connect(ac.destination);
          o.start(at); o.stop(at + 1);
        }
      }
      setTimeout(() => ac.close(), 5000);
    } catch {}
  }

  function renderAlarm() {
    $("title").textContent = state.title;
    $("subtitle").textContent = state.subtitle;
    answer.replaceChildren();
    copy.classList.remove("ready");
    for (const id of ["ask", "approval", "ring", "note"]) $(id).hidden = true;
    renderClocks(false);
    $("alarmButtons").hidden = false;
    $("snooze").textContent = L10n.ui("snooze");
    $("alarmDone").textContent = L10n.ui("done");
    if (state.sound && chimedFor !== state.since) { chimedFor = state.since; chime(); }
    requestAnimationFrame(() => clawd.send("card-height", card.getBoundingClientRect().height));
  }
  $("snooze").addEventListener("click", () => clawd.send("alarm-answer", true));
  $("alarmDone").addEventListener("click", () => clawd.send("alarm-answer", false));

  function render() {
    L10n.lang = state.lang;
    card.classList.toggle("thinking", false);
    $("alarmButtons").hidden = state.view !== "alarm";
    if (state.view === "alarm") { renderAlarm(); return; }
    if (state.view === "approval") { renderClocks(false); renderApproval(); return; }
    $("approval").hidden = true;
    $("ring").hidden = true;
    const chat = state.view === "chat";
    const thinking = chat && state.phase === "thinking";
    card.classList.toggle("thinking", thinking);
    $("title").textContent = thinking ? L10n.ui(state.looking ? "screenLooking" : "chatThinking")
      : state.phase === "input" ? L10n.buddyName : "";
    $("attach").classList.toggle("on", !!state.attach);
    $("attach").title = L10n.ui("screenAttach");
    $("subtitle").textContent = state.question || "";
    renderAnswer(state.phase === "answer" ? state.answer : "", state.error);
    $("note").textContent = state.note ? "⚠ " + state.note : "";
    $("note").hidden = !state.note || state.phase !== "answer";
    answer.style.maxHeight = `${Math.max(120, state.maxHeight - 120)}px`;
    copy.textContent = L10n.ui("copy");
    copy.classList.toggle("ready", state.phase === "answer" && !!state.answer);
    $("ask").hidden = !chat;
    renderClocks(chat);
    input.placeholder = L10n.ui(state.phase === "input" ? "chatPlaceholder" : "chatMore");
    if (chat && !thinking) input.focus();
    requestAnimationFrame(() => clawd.send("card-height", card.getBoundingClientRect().height));
  }

  $("ask").addEventListener("submit", (e) => {
    e.preventDefault();
    const text = input.value.trim();
    if (!text || state?.phase === "thinking") return;
    input.value = "";
    clawd.send("card-submit", text);
  });

  function copyAnswer() {
    if (!state?.answer) return;
    clawd.send("card-copy", state.answer);
    copy.textContent = L10n.ui("copied");
    setTimeout(() => { copy.textContent = L10n.ui("copy"); }, 1500);
  }
  copy.addEventListener("click", copyAnswer);
  $("attach").addEventListener("click", () => { clawd.send("card-attach"); input.focus(); });
  answer.addEventListener("contextmenu", (e) => { e.preventDefault(); copyAnswer(); });

  document.addEventListener("keydown", (e) => { if (e.key === "Escape") clawd.send("card-close"); });

  // Files can be dropped on the open card too.
  window.addEventListener("dragover", (e) => e.preventDefault());
  window.addEventListener("drop", (e) => {
    e.preventDefault();
    const file = e.dataTransfer.files[0];
    const p = file && clawd.pathForFile(file);
    if (p) clawd.send("file-dropped", p);
  });

  clawd.on("card-state", (s) => { state = s; render(); });
})();
