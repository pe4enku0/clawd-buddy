// Pixel crab, speech bubble and particles on a canvas. Port of macos/Sources/BuddyView.swift.
// Coordinates are in a fixed 380×136 "base" space with y pointing down; the canvas is scaled to fit.
(function () {
  const UNIT = 6, GRID_W = 14, GRID_H = 10;
  const BASE_W = 380, BASE_H = 136;

  const C = {
    body: "#D97757", shade: "#C36548", legs: "#B0583D", eye: "#1F1410", ink: "#2B1C17", ivory: "#FAF9F5",
    lid: "#3D3D3A", lidEdge: "#55544E", keyboard: "#B9B5AA", keyboardShade: "#9C988D",
    paperLine: "#B9B5AA", paperEdge: "#E3DED3",
    confetti: ["#D97757", "#E8B04B", "#6A9BCC", "#7FB77E", "#C46686"],
    claudeFill: (dark) => (dark ? "#30302E" : "#FAF9F5"),
    claudeBorder: (dark) => (dark ? "#4A4945" : "#DEDAD0"),
    claudeText: (dark) => (dark ? "#F5F4EF" : "#141413"),
  };

  const FONT_PIXEL = '600 12px "Cascadia Mono", Consolas, "SF Mono", Menlo, monospace';
  const FONT_SERIF = '13.5px Georgia, "Iowan Old Style", "Times New Roman", serif';
  const FONT_TAG = '600 9.5px "Segoe UI", system-ui, -apple-system, sans-serif';
  const FONT_PARTICLE = (s) => `800 ${s}px "Cascadia Mono", Consolas, Menlo, "Segoe UI Emoji", monospace`;

  const ACT_LENGTH = { lookAround: 72, stretch: 50, dance: 72, hop: 36, wave: 48, yawn: 40, wiggle: 30 };
  const ACTS = Object.keys(ACT_LENGTH);

  const EYES = {
    open: [[0, 2], [0, 3]], lookLeft: [[-1, 2], [-1, 3]], lookRight: [[1, 2], [1, 3]],
    lookUp: [[0, 1], [0, 2]], lookDown: [[0, 3], [0, 4]], closed: [[-1, 3], [0, 3], [1, 3]],
    happy: [[-1, 3], [-1, 2], [0, 2], [1, 2], [1, 3]], wide: [[0, 1], [0, 2], [0, 3]], squint: [[-1, 3], [0, 3]],
  };
  const ARMS = {
    down: [[0, 4], [1, 4], [0, 5], [1, 5]], low: [[0, 5], [1, 5], [0, 6], [1, 6]], up: [[1, 3], [0, 2], [1, 2], [0, 1]],
  };

  const rand = (a, b) => a + Math.random() * (b - a);
  const pickOf = (arr) => arr[Math.floor(Math.random() * arr.length)];

  /** Paints a pose with its top-left grid cell at (x, y). */
  function paint(ctx, p, x, y, u) {
    const fill = (c, r, w, h, color) => {
      ctx.fillStyle = color;
      ctx.fillRect(Math.round(x + c * u), Math.round(y + r * u), Math.round(w * u), Math.round(h * u));
    };
    for (const c of p.legs === "stand" ? [3, 5, 8, 10] : [2, 4, 9, 11]) fill(c, 8, 1, 2, C.legs);
    const cr = p.crouch;
    fill(2, cr, 10, 8, C.body);
    fill(2, 7 + cr, 10, 1, C.shade);
    for (const [left, arm] of [[true, p.lArm], [false, p.rArm]]) {
      for (const [c, r] of ARMS[arm]) fill(left ? c : 13 - c, r + cr, 1, 1, C.body);
    }
    for (const center of [4, 9]) for (const [dc, r] of EYES[p.eyes]) fill(center + dc, r + cr, 1, 1, C.eye);

    if (p.prop === "laptop") {
      fill(3, 5, 8, 3, C.lid);
      fill(3, 5, 8, 1, C.lidEdge);
      fill(7, 6, 1, 1, C.confetti[1]);
      fill(2, 8, 10, 1, C.keyboard);
      fill(2, 9, 10, 1, C.keyboardShade);
    } else if (p.prop === "paper") {
      fill(4, 5 + cr, 6, 4, C.ivory);
      fill(9, 5 + cr, 1, 4, C.paperEdge);
      const lines = p.paperScroll === 0 ? [[6, 4], [7, 3]] : [[6, 3], [7, 4]];
      for (const [r, w] of lines) fill(5, r + cr, w, 1, C.paperLine);
    }
  }

  function wrap(ctx, text, maxW) {
    const lines = [];
    for (const para of text.split("\n")) {
      let line = "";
      for (const word of para.split(/(\s+)/)) {
        const next = line + word;
        if (ctx.measureText(next).width <= maxW || !line.trim()) { line = next; continue; }
        lines.push(line.trimEnd());
        line = word.trimStart();
      }
      // hard-break anything still too wide (long paths, commands)
      while (ctx.measureText(line).width > maxW) {
        let i = line.length;
        while (i > 1 && ctx.measureText(line.slice(0, i)).width > maxW) i--;
        lines.push(line.slice(0, i));
        line = line.slice(i);
      }
      lines.push(line);
    }
    return lines;
  }

  class BuddyView {
    constructor(canvas) {
      this.canvas = canvas;
      this.ctx = canvas.getContext("2d");
      this.sprite = document.createElement("canvas");
      this.style = "pixel";
      this.followMouse = true;
      this.mouse = null; // base coords, may be outside the view
      this.dark = matchMedia("(prefers-color-scheme: dark)").matches;
      matchMedia("(prefers-color-scheme: dark)").addEventListener("change", (e) => { this.dark = e.matches; });

      this.mood = "idle";
      this.isDragging = false;
      this.dragMoved = false;
      this.tick = 0; this.moodTick = 0;
      this.blinkUntil = 0; this.nextBlink = 90;
      this.jumpStart = -100; this.jumpLen = 14; this.jumpHeight = 4;
      this.pokeUntil = 0; this.squishUntil = 0;
      this.act = null; this.actTick = 0;
      this.particles = [];

      this.bubbleText = ""; this.bubbleChars = []; this.bubbleShown = 0;
      this.bubbleShowing = false; this.bubbleAlpha = 0;
      this.lines = []; this.textW = 0;
      this.resize(1);
    }

    resize(scale) {
      this.scale = scale;
      const dpr = window.devicePixelRatio || 1;
      this.canvas.width = Math.round(BASE_W * scale * dpr);
      this.canvas.height = Math.round(BASE_H * scale * dpr);
      this.canvas.style.width = `${BASE_W * scale}px`;
      this.canvas.style.height = `${BASE_H * scale}px`;
      this.sprite.width = Math.ceil((GRID_W * UNIT + 4) * scale * dpr);
      this.sprite.height = Math.ceil((GRID_H * UNIT + 4) * scale * dpr);
    }

    // ---- geometry (base coords)
    get crabOrigin() { return { x: BASE_W - GRID_W * UNIT - 14, y: 52 }; }
    get eyeLevel() { return this.crabOrigin.y + 3 * UNIT; }
    get crabRect() {
      const o = this.crabOrigin;
      return { x: o.x - 4, y: o.y - 30, w: GRID_W * UNIT + 8, h: GRID_H * UNIT + 34 };
    }
    get padding() { return this.style === "pixel" ? { w: 10, h: 7 } : { w: 13, h: 9 }; }
    get headerHeight() { return this.style === "claude" ? 15 : 0; }
    get lineHeight() { return this.style === "pixel" ? 15 : 19; }
    get bubbleRect() {
      const w = this.textW + this.padding.w * 2;
      const h = this.lines.length * this.lineHeight + this.padding.h * 2 + this.headerHeight;
      const right = this.crabOrigin.x - 12;
      return { x: right - w, y: Math.max(4, this.eyeLevel - h / 2), w, h };
    }
    get hovering() { return !!this.mouse && inside(this.crabRect, this.mouse); }
    get isActing() { return this.act !== null; }

    isInteractive(p) {
      if (inside(this.crabRect, p)) return true;
      if (!this.bubbleShowing) return false;
      const r = this.bubbleRect;
      return inside({ x: r.x - 2, y: r.y - 2, w: r.w + 4, h: r.h + 4 }, p);
    }
    isOnBubble(p) { return this.bubbleShowing && inside(this.bubbleRect, p) && !inside(this.crabRect, p); }

    // ---- control
    setStyle(s) { this.style = s; this.measure(); }
    setMood(m) {
      if (m === this.mood) return;
      this.mood = m; this.moodTick = 0; this.act = null;
      if (m === "done") this.burstConfetti();
    }
    jump(h = 4) { this.jumpStart = this.tick; this.jumpHeight = h; this.jumpLen = Math.floor(10 + h * 1.5); }
    play(a) { this.act = a; this.actTick = 0; if (a === "hop") this.jump(3); }
    randomAct() { return pickOf(ACTS); }
    say(text) {
      this.bubbleText = text; this.bubbleChars = Array.from(text); this.bubbleShown = 0;
      this.bubbleShowing = true; this.measure();
    }
    hideBubble() { this.bubbleShowing = false; }
    poke() { this.pokeUntil = this.tick + 24; this.jump(3); }
    landed() { this.squishUntil = this.tick + 5; }
    startDragMotion() { this.dragMoved = true; this.act = null; }

    measure() {
      const ctx = this.ctx;
      ctx.save();
      ctx.font = this.style === "pixel" ? FONT_PIXEL : FONT_SERIF;
      this.lines = wrap(ctx, this.bubbleText, 230);
      this.textW = Math.max(this.style === "claude" ? 40 : 0, ...this.lines.map((l) => Math.ceil(ctx.measureText(l).width)));
      ctx.restore();
    }

    // ---- animation
    step() {
      this.tick++; this.moodTick++;
      if (this.tick >= this.nextBlink) { this.blinkUntil = this.tick + 4; this.nextBlink = this.tick + Math.floor(rand(70, 170)); }
      if (this.mood === "waiting" && this.moodTick % 60 === 1) this.jump(2.5);

      if (this.act) {
        this.actTick++;
        if (this.act === "hop" && this.actTick === 18) this.jump(2.5);
        if (this.act === "dance" && this.actTick % 12 === 1) this.emit(["♪", "♫"], C.body);
        if (this.actTick >= ACT_LENGTH[this.act]) this.act = null;
      }

      this.spawnParticles();
      this.particles = this.particles.filter((p) => {
        p.vy += p.g; p.x += p.vx; p.y += p.vy; p.life -= 1;
        return p.life > 0;
      });

      if (this.bubbleShowing) {
        this.bubbleAlpha = Math.min(1, this.bubbleAlpha + 0.2);
        if (this.bubbleShown < this.bubbleChars.length) {
          this.bubbleShown = Math.min(this.bubbleChars.length, this.bubbleShown + (this.bubbleChars.length > 40 ? 2 : 1));
        }
      } else {
        this.bubbleAlpha = Math.max(0, this.bubbleAlpha - 0.12);
      }

      // Sleeping with nothing moving doesn't need 30 fps.
      if (this.mood !== "sleeping" || this.particles.length || this.bubbleAlpha > 0 || this.tick % 3 === 0) this.draw();
    }

    spawnParticles() {
      const t = this.moodTick, every = (n) => t % n === 1;
      switch (this.mood) {
        case "writing": if (every(9)) this.emit(["{ }", ";", "</>", "()", "=>", "#", "[ ]"], C.body); break;
        case "thinking": if (every(32)) this.emit(["?", "…", "?"], C.ink); break;
        case "running": if (every(14)) this.emit([">_", "⚡", "⚙"], C.body); break;
        case "agent": if (every(20)) this.emit(["🦀", "⚡"], C.body); break;
        case "searching": if (every(26)) this.emit(["🔍"], C.ink); break;
        case "web": if (every(26)) this.emit(["🌐"], C.ink); break;
        case "waiting": if (every(30)) this.emit(["!"], C.body); break;
        case "done": if (t < 70 && every(5)) this.emit(["✦", "✧", "★"], C.body); break;
        case "sleeping": if (every(40)) this.emit(["z", "Z"], C.ink); break;
        case "oops": if (every(40)) this.emit(["💦"], C.ink); break;
        case "reading": if (every(60)) this.emit(["📖"], C.ink); break;
      }
    }

    emit(texts, color) {
      const o = this.crabOrigin;
      this.particles.push({
        text: pickOf(texts), x: o.x + rand(12, 64), y: o.y - 6, vx: rand(-0.7, 0.15), vy: -rand(0.45, 0.85), g: 0,
        life: 52, maxLife: 52, color, size: 12, outlined: true,
      });
    }

    burstConfetti() {
      const o = this.crabOrigin;
      for (let i = 0; i < 22; i++) {
        this.particles.push({
          text: pickOf(["■", "●", "▲", "✦"]), x: o.x + rand(20, 60), y: o.y + 6, vx: rand(-2.6, 1.0), vy: -rand(2.2, 4.2),
          g: 0.13, life: 64, maxLife: 64, color: pickOf(C.confetti), size: rand(7, 10), outlined: false,
        });
      }
    }

    eyesToward(m) {
      const cx = this.crabOrigin.x + 7 * UNIT, cy = this.eyeLevel;
      const dx = m.x - cx, dy = m.y - cy;
      if (Math.hypot(dx, dy) > 700 || (Math.abs(dx) < 20 && Math.abs(dy) < 20)) return "open";
      if (Math.abs(dy) > Math.abs(dx) * 1.3) return dy < 0 ? "lookUp" : "lookDown";
      return dx < 0 ? "lookLeft" : "lookRight";
    }

    pose() {
      const p = { eyes: "open", lArm: "down", rArm: "down", legs: "stand", prop: "none", crouch: 0, dx: 0, lift: 0, paperScroll: 0 };
      const t = this.moodTick, f = Math.floor;
      let follow = false;
      switch (this.mood) {
        case "idle": p.crouch = f(t / 26) % 2; follow = true; break;
        case "thinking":
          p.crouch = f(t / 20) % 2; p.eyes = f(t / 25) % 2 === 0 ? "lookUp" : "lookLeft"; p.lArm = "low"; break;
        case "writing": {
          const k = f(t / 4) % 2;
          p.lArm = k === 0 ? "down" : "low"; p.rArm = k === 0 ? "low" : "down";
          p.prop = "laptop"; p.eyes = f(t / 40) % 4 === 3 ? "lookLeft" : "lookDown"; break;
        }
        case "reading":
          p.prop = "paper"; p.lArm = "low"; p.rArm = "low";
          p.eyes = f(t / 14) % 2 === 0 ? "lookDown" : "open"; p.crouch = f(t / 30) % 2; p.paperScroll = f(t / 15) % 2; break;
        case "searching": case "web":
          p.legs = f(t / 4) % 2 === 0 ? "stand" : "splay"; p.dx = [0, -1, 0, 1][f(t / 6) % 4];
          p.eyes = f(t / 12) % 2 === 0 ? "lookLeft" : "lookRight"; break;
        case "running": case "agent":
          p.legs = f(t / 3) % 2 === 0 ? "stand" : "splay"; p.crouch = f(t / 6) % 2;
          p.lArm = f(t / 6) % 2 === 0 ? "low" : "down"; p.rArm = f(t / 6) % 2 === 0 ? "down" : "low"; break;
        case "waiting": p.lArm = f(t / 8) % 2 === 0 ? "up" : "down"; p.eyes = "wide"; follow = true; break;
        case "done":
          p.eyes = "happy"; if (t < 60) { p.lArm = "up"; p.rArm = "up"; } p.crouch = f(t / 15) % 2; break;
        case "sleeping": p.eyes = "closed"; p.crouch = f(t / 45) % 2 === 0 ? 1 : 0; break;
        case "oops":
          p.eyes = "squint"; p.crouch = 1; p.lArm = "low"; p.rArm = "low";
          if (t < 18) p.dx = f(t / 2) % 2 === 0 ? -1 : 1; break;
      }

      if (this.act) {
        const at = this.actTick;
        switch (this.act) {
          case "lookAround":
            p.eyes = at < 18 ? "lookLeft" : at < 26 ? "open" : at < 44 ? "lookRight" : at < 58 ? "lookUp" : "open"; break;
          case "stretch":
            if (at < 8) p.crouch = 1;
            else if (at < 42) { p.crouch = 0; p.lArm = "up"; p.rArm = "up"; p.eyes = "closed"; }
            break;
          case "dance": {
            const beat = f(at / 6);
            p.dx = [-1, 0, 1, 0][beat % 4];
            p.lArm = beat % 2 === 0 ? "up" : "down"; p.rArm = beat % 2 === 0 ? "down" : "up";
            p.legs = beat % 2 === 0 ? "splay" : "stand"; p.eyes = "happy"; break;
          }
          case "hop": p.eyes = "happy"; break;
          case "wave": p.lArm = f(at / 7) % 2 === 0 ? "up" : "down"; p.eyes = "happy"; break;
          case "yawn": p.eyes = "closed"; p.crouch = 1; p.lArm = "low"; p.rArm = "low"; break;
          case "wiggle": p.dx = [0, 1, 0, -1][f(at / 3) % 4]; p.eyes = "happy"; break;
        }
        follow = false;
      }

      if (follow && this.followMouse && this.mouse) p.eyes = this.eyesToward(this.mouse);
      if (this.hovering && !this.isDragging && (this.mood === "idle" || this.mood === "done") && !this.act) p.eyes = "happy";
      if (this.tick < this.blinkUntil && ["open", "lookLeft", "lookRight", "lookUp", "lookDown", "wide"].includes(p.eyes)) p.eyes = "closed";
      if (this.tick < this.pokeUntil) { p.eyes = "wide"; p.lArm = "up"; p.rArm = "up"; }

      if (this.isDragging && this.dragMoved) {
        p.legs = f(this.tick / 3) % 2 === 0 ? "stand" : "splay"; p.eyes = "wide";
        p.lArm = f(this.tick / 4) % 2 === 0 ? "up" : "low"; p.rArm = f(this.tick / 4) % 2 === 0 ? "low" : "up";
        p.prop = "none"; p.crouch = 0; p.dx = 0;
      }

      const jt = this.tick - this.jumpStart;
      if (jt >= 0 && jt < this.jumpLen) {
        p.lift = Math.sin((Math.PI * jt) / this.jumpLen) * this.jumpHeight; p.crouch = 0;
      } else if ((jt >= this.jumpLen && jt < this.jumpLen + 3) || this.tick < this.squishUntil) {
        p.crouch = 1; // landing squish
      }
      return p;
    }

    // ---- drawing
    draw() {
      const ctx = this.ctx, dpr = window.devicePixelRatio || 1, k = this.scale * dpr;
      ctx.setTransform(1, 0, 0, 1, 0, 0);
      ctx.clearRect(0, 0, this.canvas.width, this.canvas.height);
      ctx.setTransform(k, 0, 0, k, 0, 0);

      const p = this.pose();
      this.drawShadow(p);
      this.drawParticles();
      this.drawCrab(p, k);
      if (this.badge) this.drawBadge();
      if (this.bubbleAlpha > 0.01 && this.bubbleChars.length) {
        this.style === "pixel" ? this.drawPixelBubble() : this.drawClaudeBubble();
      }
    }

    /** A small pill under the crab: a timer counting down (clay) or the stopwatch (ink). */
    drawBadge() {
      const ctx = this.ctx, o = this.crabOrigin;
      ctx.font = '700 10.5px "Cascadia Mono", Consolas, "SF Mono", Menlo, monospace';
      const text = this.badge.text, w = Math.ceil(ctx.measureText(text).width) + 14, h = 15;
      const x = Math.round(o.x + 7 * UNIT - w / 2), y = 120;
      ctx.fillStyle = "rgba(250, 249, 245, 0.92)";
      ctx.strokeStyle = "rgba(43, 28, 23, 0.25)";
      ctx.lineWidth = 1;
      ctx.beginPath();
      ctx.roundRect(x + 0.5, y + 0.5, w - 1, h - 1, 7);
      ctx.fill();
      ctx.stroke();
      ctx.fillStyle = this.badge.kind === "timer" ? "#C4673F" : C.ink;
      ctx.textBaseline = "middle";
      ctx.fillText(text, x + 7, y + h / 2 + 0.5);
    }

    drawShadow(p) {
      const ctx = this.ctx, o = this.crabOrigin;
      const w = 10 * UNIT - p.lift * 5;
      ctx.fillStyle = `rgba(0,0,0,${Math.max(0.05, 0.22 - p.lift * 0.02)})`;
      ctx.beginPath();
      ctx.ellipse(o.x + 7 * UNIT + p.dx * UNIT, o.y + 10 * UNIT + 2, w / 2, 3, 0, 0, Math.PI * 2);
      ctx.fill();
    }

    drawCrab(p, k) {
      // Paint into an offscreen sprite at device resolution, then stamp it with one soft shadow.
      const s = this.sprite.getContext("2d");
      s.setTransform(1, 0, 0, 1, 0, 0);
      s.clearRect(0, 0, this.sprite.width, this.sprite.height);
      s.imageSmoothingEnabled = false;
      paint(s, p, 2 * k, 2 * k, UNIT * k);

      const o = this.crabOrigin, ctx = this.ctx;
      const x = o.x + p.dx * UNIT - 2, y = o.y - Math.round(p.lift * UNIT) - 2;
      ctx.save();
      ctx.shadowColor = "rgba(0,0,0,0.35)";
      ctx.shadowBlur = 4 * k;
      ctx.shadowOffsetY = 1 * k;
      ctx.imageSmoothingEnabled = false;
      ctx.drawImage(this.sprite, x, y, this.sprite.width / k, this.sprite.height / k);
      ctx.restore();
    }

    visibleLines() {
      let left = this.bubbleShown;
      const out = [];
      for (const line of this.lines) {
        const chars = Array.from(line);
        if (left <= 0) break;
        out.push(chars.slice(0, left).join(""));
        left -= chars.length + 1;
      }
      return out;
    }

    pixelBox(r, n = 3) {
      const { x, y } = r, X = r.x + r.w, Y = r.y + r.h, ctx = this.ctx;
      const pts = [[x + n, y], [X - n, y], [X - n, y + n], [X, y + n], [X, Y - n], [X - n, Y - n],
                   [X - n, Y], [x + n, Y], [x + n, Y - n], [x, Y - n], [x, y + n], [x + n, y + n]];
      ctx.beginPath();
      ctx.moveTo(...pts[0]);
      for (const pt of pts.slice(1)) ctx.lineTo(...pt);
      ctx.closePath();
    }

    drawPixelBubble() {
      const ctx = this.ctx, b = this.bubbleRect;
      const r = { ...b, x: b.x + (1 - this.bubbleAlpha) * 6 };
      const X = r.x + r.w, ty = this.eyeLevel;
      ctx.save();
      ctx.globalAlpha = this.bubbleAlpha;

      ctx.fillStyle = "rgba(0,0,0,0.25)";
      this.pixelBox({ ...r, x: r.x + 3, y: r.y + 3 }); ctx.fill();
      ctx.fillRect(X + 1, ty - 4, 9, 8);

      ctx.fillStyle = C.ink;
      this.pixelBox(r); ctx.fill();
      ctx.fillRect(X - 2, ty - 7, 7, 14);
      ctx.fillRect(X + 5, ty - 4, 5, 8);

      ctx.fillStyle = C.ivory;
      this.pixelBox({ x: r.x + 2, y: r.y + 2, w: r.w - 4, h: r.h - 4 }, 2); ctx.fill();
      ctx.fillRect(X - 4, ty - 5, 7, 10);
      ctx.fillRect(X + 3, ty - 2, 5, 4);

      ctx.fillStyle = C.ink;
      ctx.font = FONT_PIXEL;
      ctx.textBaseline = "top";
      this.visibleLines().forEach((l, i) => ctx.fillText(l, r.x + this.padding.w, r.y + this.padding.h + 1 + i * this.lineHeight));
      ctx.restore();
    }

    drawClaudeBubble() {
      const ctx = this.ctx, dark = this.dark, b = this.bubbleRect;
      const x = b.x + (1 - this.bubbleAlpha) * 6, y = b.y, X = x + b.w, Y = y + b.h;
      const rad = 12, ty = this.eyeLevel;

      const path = new Path2D();
      path.moveTo(x + rad, y);
      path.arcTo(X, y, X, Y, rad);
      path.lineTo(X, ty - 6);
      path.bezierCurveTo(X + 3, ty - 3, X + 7, ty - 1, X + 9, ty);
      path.bezierCurveTo(X + 7, ty + 1, X + 3, ty + 3, X, ty + 6);
      path.arcTo(X, Y, x, Y, rad);
      path.arcTo(x, Y, x, y, rad);
      path.arcTo(x, y, X, y, rad);
      path.closePath();

      ctx.save();
      ctx.globalAlpha = this.bubbleAlpha;
      ctx.save();
      ctx.shadowColor = dark ? "rgba(0,0,0,0.45)" : "rgba(0,0,0,0.16)";
      ctx.shadowBlur = 12 * this.scale * (window.devicePixelRatio || 1);
      ctx.shadowOffsetY = 3 * this.scale * (window.devicePixelRatio || 1);
      ctx.fillStyle = C.claudeFill(dark);
      ctx.fill(path);
      ctx.restore();
      ctx.strokeStyle = C.claudeBorder(dark);
      ctx.lineWidth = 1;
      ctx.stroke(path);

      ctx.textBaseline = "top";
      ctx.font = FONT_TAG;
      ctx.letterSpacing = "0.9px";
      ctx.fillStyle = C.body;
      ctx.fillText(L10n.buddyName.toUpperCase(), x + this.padding.w, y + this.padding.h - 1);
      ctx.letterSpacing = "0px";

      ctx.font = FONT_SERIF;
      ctx.fillStyle = C.claudeText(dark);
      this.visibleLines().forEach((l, i) =>
        ctx.fillText(l, x + this.padding.w, y + this.padding.h + this.headerHeight + 1 + i * this.lineHeight));
      ctx.restore();
    }

    drawParticles() {
      const ctx = this.ctx;
      ctx.save();
      ctx.textBaseline = "top";
      ctx.lineJoin = "round";
      for (const p of this.particles) {
        const a = Math.min(1, (p.life / p.maxLife) * 1.6);
        ctx.font = FONT_PARTICLE(p.size);
        ctx.globalAlpha = a;
        if (p.outlined) {
          ctx.strokeStyle = "rgba(255,255,255,0.9)";
          ctx.lineWidth = 3;
          ctx.strokeText(p.text, p.x, p.y);
        }
        ctx.fillStyle = p.color;
        ctx.fillText(p.text, p.x, p.y);
      }
      ctx.restore();
    }
  }

  function inside(r, p) { return p.x >= r.x && p.x <= r.x + r.w && p.y >= r.y && p.y <= r.y + r.h; }

  /** A waving crab drawn into `canvas` at `unit` CSS px per grid cell (for the settings header). */
  BuddyView.drawStatic = function (canvas, unit, happy) {
    const dpr = window.devicePixelRatio || 1;
    canvas.width = GRID_W * unit * dpr;
    canvas.height = GRID_H * unit * dpr;
    canvas.style.width = `${GRID_W * unit}px`;
    canvas.style.height = `${GRID_H * unit}px`;
    const ctx = canvas.getContext("2d");
    paint(ctx, { eyes: happy ? "happy" : "open", lArm: "up", rArm: "down", legs: "stand", prop: "none", crouch: 0 },
          0, 0, unit * dpr);
  };

  window.BuddyView = BuddyView;
  window.BuddyBase = { W: BASE_W, H: BASE_H };
})();
