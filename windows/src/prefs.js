// Persisted settings in <userData>/prefs.json.
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

const DEFAULTS = {
  lang: "en",
  bubbleStyle: "pixel",
  size: "medium",
  chattiness: 0.3,
  idleChatter: true,
  followMouse: true,
  hideWhenSleeping: false,
  launchAtLogin: true,
  chatHotkey: "Control+Alt+Space", // Electron accelerator; Alt+Space is the window menu on Windows
  approvalCard: true,
  anchor: null, // top-right corner of the buddy window, in screen DIPs
  firstRunDone: false,
};

const VALID = {
  lang: ["en", "ru"],
  bubbleStyle: ["pixel", "claude"],
  size: ["small", "medium", "large"],
};

/** A global shortcut with Ctrl, Alt or Win in it, so it can't hijack plain typing. */
function isHotkey(v) {
  return typeof v === "string" && v.length < 60
    && /^(?:(?:Control|Alt|Shift|Super)\+)+(?:[A-Z0-9]|F(?:[1-9]|1[0-9]|2[0-4])|Space|Up|Down|Left|Right)$/.test(v)
    && /(?:Control|Alt|Super)\+/.test(v);
}

class Prefs {
  constructor(dir) {
    this.file = path.join(dir, "prefs.json");
    let saved = {};
    try { saved = JSON.parse(fs.readFileSync(this.file, "utf8")); } catch {}
    this.data = { ...DEFAULTS, ...saved };
  }

  get(key) { return this.data[key]; }

  set(key, value) {
    if (!(key in DEFAULTS)) return false;
    if (VALID[key] && !VALID[key].includes(value)) return false;
    if (key === "chatHotkey" && !isHotkey(value)) return false;
    if (typeof DEFAULTS[key] === "boolean") value = !!value;
    if (key === "chattiness") value = Math.min(1, Math.max(0, Number(value) || 0));
    this.data[key] = value;
    this.save();
    return true;
  }

  /** Secret part of the hook URL; created once. Not in DEFAULTS, so set() can't touch it. */
  hookToken() {
    if (typeof this.data.hookToken !== "string" || this.data.hookToken.length < 32) {
      this.data.hookToken = crypto.randomBytes(24).toString("hex");
      this.save();
    }
    return this.data.hookToken;
  }

  /** What the renderers get to see. */
  get public() {
    const { anchor, firstRunDone, hookToken, ...rest } = this.data;
    return rest;
  }

  save() {
    try {
      fs.mkdirSync(path.dirname(this.file), { recursive: true });
      fs.writeFileSync(this.file, JSON.stringify(this.data, null, 2));
    } catch (e) {
      console.error("prefs save failed", e);
    }
  }
}

module.exports = { Prefs, isHotkey };
