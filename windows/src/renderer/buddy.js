// Wires the view and brain to the main process: hook events, cursor, prefs, mouse.
(function () {
  const SCALE = { small: 2 / 3, medium: 1, large: 4 / 3 };
  const canvas = document.getElementById("buddy");
  const view = new BuddyView(canvas);
  const prefs = { chattiness: 0.3, idleChatter: true, followMouse: true, hideWhenSleeping: false, size: "medium" };
  const brain = new Brain(view, prefs);
  let interactive = false;
  let faded = false;

  function applyPrefs(p) {
    Object.assign(prefs, p);
    L10n.lang = p.lang;
    view.followMouse = p.followMouse;
    if (view.style !== p.bubbleStyle) view.setStyle(p.bubbleStyle);
    if (view.scale !== SCALE[p.size]) view.resize(SCALE[p.size]);
    view.measure();
  }

  /** Click-through everywhere except the crab and its bubble. */
  function updateInteractive() {
    const want = !faded && (view.isDragging || (!!view.mouse && view.isInteractive(view.mouse)));
    if (want !== interactive) {
      interactive = want;
      clawd.send("interactive", want);
    }
  }

  const toBase = (e) => ({ x: e.clientX / view.scale, y: e.clientY / view.scale });

  clawd.on("prefs", applyPrefs);
  clawd.on("hook", (info) => brain.handle(info));
  clawd.on("badge", (b) => { view.badge = b; });
  clawd.on("cursor", (p) => { view.mouse = p; updateInteractive(); });
  clawd.on("drag-moved", () => { view.startDragMotion(); brain.dragStarted(); });
  clawd.on("command", (cmd) => {
    if (cmd === "greet") brain.greet();
    else if (cmd === "demo") brain.demo();
    else if (cmd === "remind") brain.remindToConnect();
    else if (cmd === "answered") brain.permissionAnswered();
    else if (cmd === "alarm") { view.play("wave"); view.jump(3); }
  });

  canvas.addEventListener("mousedown", (e) => {
    if (e.button !== 0) return;
    view.isDragging = true;
    view.dragMoved = false;
    clawd.send("drag-start");
  });

  async function endDrag(e) {
    if (!view.isDragging) return;
    view.isDragging = false;
    const moved = await clawd.invoke("drag-end");
    view.dragMoved = false;
    if (moved) {
      view.landed();
      brain.dropped();
    } else if (e && view.isOnBubble(toBase(e))) {
      view.hideBubble();
    } else if (e) {
      view.poke();
      brain.poked();
    }
  }
  window.addEventListener("mouseup", (e) => { if (e.button === 0) endDrag(e); });
  window.addEventListener("blur", () => endDrag(null));

  // A file dragged onto the crab: the window takes drops while the cursor is over the crab.
  let dragNote = false;
  window.addEventListener("dragover", (e) => {
    e.preventDefault();
    if (!dragNote) { dragNote = true; brain.fileOver(); }
  });
  window.addEventListener("dragleave", () => { if (dragNote) { dragNote = false; brain.fileGone(); } });
  window.addEventListener("drop", (e) => {
    e.preventDefault();
    dragNote = false;
    brain.fileGone();
    const file = e.dataTransfer.files[0];
    const p = file && clawd.pathForFile(file);
    if (p) clawd.send("file-dropped", p);
  });

  canvas.addEventListener("contextmenu", (e) => {
    e.preventDefault();
    clawd.send("show-menu");
  });

  setInterval(() => {
    brain.tick();
    const fade = prefs.hideWhenSleeping && view.mood === "sleeping";
    if (fade !== faded) {
      faded = fade;
      canvas.style.opacity = fade ? "0" : "1";
      updateInteractive();
    }
  }, 1000 / 30);

  clawd.send("ready");
})();
