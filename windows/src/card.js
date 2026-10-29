// The card next to the crab: the Windows stand-in for the Mac notch's expanded states.
// A frameless window that sits under the buddy (or above it near the bottom of the screen),
// grows with its content and reports back what the page asks for.
const { BrowserWindow, screen } = require("electron");
const path = require("path");

const WIDTH = 400;
const PAD = 14;           // transparent margin around the card, for its shadow
const MAX_SHARE = 0.7;    // the card may take this much of the screen height before it scrolls

class Card {
  /** buddyBounds(): the crab window's bounds; onBlur(): the card lost focus (a click elsewhere). */
  constructor({ preload, buddyBounds, onBlur }) {
    this.preload = preload;
    this.buddyBounds = buddyBounds;
    this.onBlur = onBlur;
    this.win = null;
    this.height = 120;
  }

  get webContents() { return this.win && !this.win.isDestroyed() ? this.win.webContents : null; }
  get visible() { return !!this.win && !this.win.isDestroyed() && this.win.isVisible(); }

  /** How tall the card may get on the current screen (the page uses it to cap its scroll areas). */
  maxHeight() {
    const wa = screen.getDisplayMatching(this.buddyBounds()).workArea;
    return Math.floor(wa.height * MAX_SHARE);
  }

  ensure() {
    if (this.win && !this.win.isDestroyed()) return;
    this.win = new BrowserWindow({
      width: WIDTH + 2 * PAD, height: this.height, show: false,
      transparent: true, frame: false, resizable: false, movable: false, minimizable: false, maximizable: false,
      fullscreenable: false, skipTaskbar: true, alwaysOnTop: true, hasShadow: false, backgroundColor: "#00000000",
      webPreferences: { preload: this.preload, backgroundThrottling: false },
    });
    this.win.setAlwaysOnTop(true, "screen-saver");
    this.win.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
    this.win.on("blur", () => { if (this.visible) this.onBlur(); });
    this.ready = new Promise((resolve) => this.win.webContents.once("did-finish-load", resolve));
    this.win.loadFile(path.join(__dirname, "renderer", "card.html"));
  }

  /** Shows (or updates) the card. `focus` gives it the keyboard, for typing. */
  async show(state, { focus = false } = {}) {
    this.ensure();
    await this.ready;
    this.send(state);
    this.place();
    if (!this.win.isVisible()) {
      if (focus) this.win.show(); else this.win.showInactive();
    }
    if (focus) this.win.focus();
  }

  send(state) {
    this.webContents?.send("card-state", { ...state, maxHeight: this.maxHeight() - 2 * PAD });
  }

  hide() {
    if (this.visible) this.win.hide();
  }

  /** The page measured itself. */
  setHeight(h) {
    this.height = Math.min(Math.ceil(h) + 2 * PAD, this.maxHeight());
    if (this.visible) this.place();
  }

  /** Right edge lines up with the crab; below the buddy window, or above it if there's no room. */
  place() {
    if (!this.win || this.win.isDestroyed()) return;
    const b = this.buddyBounds();
    const wa = screen.getDisplayMatching(b).workArea;
    const w = WIDTH + 2 * PAD, h = this.height;
    let x = b.x + b.width - w + PAD - 6;
    let y = b.y + b.height - PAD;
    if (y + h > wa.y + wa.height) y = b.y - h + PAD;
    x = Math.max(wa.x, Math.min(x, wa.x + wa.width - w));
    y = Math.max(wa.y, Math.min(y, wa.y + wa.height - h));
    this.win.setBounds({ x: Math.round(x), y: Math.round(y), width: w, height: h });
  }
}

module.exports = { Card, WIDTH, PAD };
