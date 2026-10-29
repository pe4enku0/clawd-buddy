// Turns Claude Code hook events into moods and lines. Port of macos/Sources/Brain.swift.
(function () {
  const MIN_LINE_GAP = 1100;
  const STREAKS = new Set([5, 10, 20, 30, 50, 100]);
  const rand = (a, b) => a + Math.random() * (b - a);
  const chance = (p) => Math.random() < p;

  const TOOL_MOOD = {
    Edit: "writing", MultiEdit: "writing", Write: "writing", NotebookEdit: "writing",
    Read: "reading", Grep: "searching", Glob: "searching", LS: "searching",
    Bash: "running", BashOutput: "running", PowerShell: "running",
    WebSearch: "web", WebFetch: "web", Agent: "agent", Task: "agent", AskUserQuestion: "waiting",
    TodoWrite: "thinking", TaskCreate: "thinking", TaskUpdate: "thinking", EnterPlanMode: "thinking", ExitPlanMode: "thinking",
  };
  const FUN = {
    writing: "funWriting", reading: "funReading", searching: "funSearching",
    running: "funRunning", web: "funWeb", agent: "funAgent",
  };

  function bashPhrase(cmd) {
    const c = cmd.toLowerCase();
    if (c.includes("git commit")) return "gitCommit";
    if (c.includes("git push")) return "gitPush";
    if (/\b(test|tests|pytest|jest|vitest|xctest|rspec)\b/.test(c)) return "tests";
    if (/\b(npm|pnpm|yarn|bun|pip3?|brew|cargo|gem|pod|winget|choco|scoop)\s+(install|add|i)\b/.test(c)) return "installing";
    if (/\b(build|make|swiftc|xcodebuild|tsc|gradle|webpack|vite|msbuild|dotnet)\b/.test(c)) return "building";
    if (/(^|[;&|]\s*)(rm|del|rmdir|remove-item)\s/.test(c)) return "deleting";
    return null;
  }

  class Brain {
    constructor(view, prefs) {
      this.view = view;
      this.prefs = prefs;
      this.turnActive = false;
      this.moodSince = Date.now();
      this.lastEventAt = Date.now();
      this.lastSayAt = 0;
      this.pending = null;
      this.bubbleHideAt = null;
      this.nextIdleActAt = Date.now() + 20000;
      this.nextSleepTalkAt = Date.now() + 40000;
      this.editsThisTurn = 0;
      this.activeSince = null;
      this.timers = [];
    }

    greet() {
      this.view.jump(4);
      const h = new Date().getHours();
      const timed = h >= 5 && h < 11 ? "greetMorning" : h >= 18 && h < 23 ? "greetEvening" : h >= 23 || h < 5 ? "greetNight" : null;
      this.sayNow(L10n.pick(timed && chance(0.5) ? timed : "greeting"));
    }

    remindToConnect() { this.sayNow(L10n.pick("notConnected"), true); }

    poked() {
      if (this.view.mood === "sleeping") { this.wakeUp(); this.sayNow(L10n.pick("wake")); }
      else this.sayNow(L10n.pick("poke"));
    }
    dragStarted() {
      if (this.view.mood === "sleeping") this.wakeUp();
      this.sayNow(L10n.pick("dragStart"), true);
    }
    dropped() { this.sayNow(L10n.pick("dropped")); }

    /** A file is being dragged onto the crab. */
    fileOver() {
      this.view.play("wave");
      this.sayNow(L10n.ui("fileDropTitle"), true);
    }

    fileGone() {
      this.view.hideBubble();
      this.bubbleHideAt = null;
    }

    /** The user allowed or denied from the card: stop waving and get back to work. */
    permissionAnswered() {
      this.view.hideBubble();
      this.bubbleHideAt = null;
      this.pending = null;
      this.set(this.turnActive ? "thinking" : "idle");
    }

    handle(info) {
      const now = Date.now();
      if (this.activeSince === null || now - this.lastEventAt > 15 * 60000) this.activeSince = now;
      this.lastEventAt = now;
      const tool = info.tool || "", detail = info.detail || "";

      switch (info.event) {
        case "SessionStart":
          this.set("idle"); this.view.jump(3);
          this.say(L10n.pick("sessionStart"));
          break;
        case "UserPromptSubmit":
          this.turnActive = true; this.editsThisTurn = 0;
          this.set("thinking"); this.view.jump(2);
          this.say(L10n.pick(new Date().getHours() < 5 && chance(0.25) ? "lateNight" : "thinking"));
          break;
        case "PreToolUse":
          this.turnActive = true;
          this.toolStarted(tool, detail);
          break;
        case "PostToolUseFailure":
          this.set("oops");
          this.say(L10n.pick("oops"));
          break;
        case "Stop":
          this.turnActive = false;
          this.set("done"); this.view.jump(5);
          this.say(L10n.pick("done"));
          if (this.activeSince !== null && now - this.activeSince > 3600000) {
            this.activeSince = now;
            this.after(5000, () => this.say(L10n.pick("breakReminder")));
          }
          break;
        case "Notification": {
          const msg = (info.message || "").toLowerCase(), kind = info.kind || "";
          this.set("waiting");
          if (kind.includes("permission") || msg.includes("permission")) this.say(L10n.pick("waitingPermission"), true);
          else if (kind.includes("idle") || msg.includes("waiting")) this.say(L10n.pick("waitingIdle"), true);
          else this.say(L10n.pick("waitingGeneric"), true);
          break;
        }
      }
    }

    toolStarted(tool, detail) {
      const m = TOOL_MOOD[tool] || "running";
      this.set(m);
      if (m === "waiting") { this.view.jump(3); this.say(L10n.pick("waitingQuestion"), true); return; }
      if (m === "writing" && STREAKS.has(++this.editsThisTurn)) {
        this.view.jump(3); this.say(L10n.streak(this.editsThisTurn)); return;
      }
      if (m === "thinking" && chance(0.5)) { this.say(L10n.pick("planning")); return; }
      const special = (tool === "Bash" || tool === "PowerShell") && bashPhrase(detail);
      if (special && chance(0.5)) { this.say(L10n.pick(special)); return; }
      if (FUN[m] && chance(this.prefs.chattiness)) { this.say(L10n.pick(FUN[m])); return; }
      this.say(L10n.action(tool, detail));
    }

    tick() {
      const now = Date.now();
      if (this.pending && now - this.lastSayAt >= MIN_LINE_GAP) {
        const p = this.pending; this.pending = null;
        this.sayNow(p.text, p.sticky);
      }
      if (this.bubbleHideAt && now >= this.bubbleHideAt) { this.view.hideBubble(); this.bubbleHideAt = null; }

      const inMood = now - this.moodSince;
      switch (this.view.mood) {
        case "writing": case "reading": case "searching": case "running": case "web": case "agent": case "oops":
          if (inMood > 6000) this.set(this.turnActive ? "thinking" : "idle"); break;
        case "thinking": if (inMood > 180000) { this.turnActive = false; this.set("idle"); } break;
        case "done": if (inMood > 10000) this.set("idle"); break;
        case "waiting": if (inMood > 120000) { this.set("sleeping"); this.view.hideBubble(); this.bubbleHideAt = null; } break;
        case "idle":
          if (now - this.lastEventAt > 120000) {
            this.set("sleeping");
            this.say(L10n.pick("sleep"));
            this.nextSleepTalkAt = now + rand(25000, 50000);
          } else if (this.prefs.idleChatter && !this.view.isActing && now >= this.nextIdleActAt) {
            this.playIdleAct();
          }
          break;
        case "sleeping":
          if (this.prefs.idleChatter && now >= this.nextSleepTalkAt) {
            this.nextSleepTalkAt = now + rand(40000, 90000);
            if (chance(0.4)) this.sayNow(L10n.pick("sleepTalk"));
          }
          break;
      }
      this.view.step();
    }

    /** A scripted tour of every mood. */
    demo() {
      this.timers.forEach(clearTimeout);
      this.timers = [];
      this.lastSayAt = 0;
      const script = [
        { event: "UserPromptSubmit" },
        { event: "PreToolUse", tool: "Read", detail: "App.tsx" },
        { event: "PreToolUse", tool: "Grep", detail: "function handle" },
        { event: "PreToolUse", tool: "Edit", detail: "App.tsx" },
        { event: "PreToolUse", tool: "Bash", detail: "npm test" },
        { event: "PostToolUseFailure", tool: "Bash" },
        { event: "PreToolUse", tool: "WebSearch", detail: "electron tray" },
        { event: "Notification", kind: "permission_prompt" },
        { event: "Stop" },
      ];
      script.forEach((ev, i) => this.after(i * 2600, () => this.handle(ev)));
      this.after(script.length * 2600 + 2000, () => this.view.play("dance"));
    }

    playIdleAct() {
      this.nextIdleActAt = Date.now() + rand(18000, 40000);
      this.view.play(this.view.randomAct());
      if (chance(0.4)) this.say(L10n.pick("idleQuip"));
    }

    wakeUp() {
      this.set("idle");
      this.lastEventAt = Date.now();
      this.nextIdleActAt = Date.now() + 20000;
      this.view.jump(2);
    }

    after(ms, fn) { this.timers.push(setTimeout(fn, ms)); }
    set(m) { this.view.setMood(m); this.moodSince = Date.now(); }

    /** Rate-limited: a burst of tool calls shows the latest line instead of flickering through all of them. */
    say(text, sticky = false) {
      if (Date.now() - this.lastSayAt < MIN_LINE_GAP) this.pending = { text, sticky };
      else this.sayNow(text, sticky);
    }

    sayNow(text, sticky = false) {
      this.lastSayAt = Date.now();
      this.pending = null;
      this.view.say(text);
      this.bubbleHideAt = sticky ? null : Date.now() + 3500 + Array.from(text).length * 50;
    }
  }

  window.Brain = Brain;
})();
