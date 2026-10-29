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

  function render() {
    L10n.lang = state.lang;
    card.classList.toggle("thinking", false);
    if (state.view === "approval") { renderApproval(); return; }
    $("approval").hidden = true;
    $("ring").hidden = true;
    const chat = state.view === "chat";
    const thinking = chat && state.phase === "thinking";
    card.classList.toggle("thinking", thinking);
    $("title").textContent = thinking ? L10n.ui("chatThinking") : state.phase === "input" ? L10n.buddyName : "";
    $("subtitle").textContent = state.question || "";
    renderAnswer(state.phase === "answer" ? state.answer : "", state.error);
    answer.style.maxHeight = `${Math.max(120, state.maxHeight - 120)}px`;
    copy.textContent = L10n.ui("copy");
    copy.classList.toggle("ready", state.phase === "answer" && !!state.answer);
    $("ask").hidden = !chat;
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
  answer.addEventListener("contextmenu", (e) => { e.preventDefault(); copyAnswer(); });

  document.addEventListener("keydown", (e) => { if (e.key === "Escape") clawd.send("card-close"); });

  clawd.on("card-state", (s) => { state = s; render(); });
})();
