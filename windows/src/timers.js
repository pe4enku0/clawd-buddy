// Timers, reminders and the stopwatch. Port of macos/Sources/Timers.swift: the same phrases in
// Russian and English, imperative only, so a question about timers stays a question.
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

// MARK: Parsing

const LEAD = String.raw`^(?:(?:clawd|клод|краб)[,!]?\s+)?(?:пожалуйста\s+|please\s+)?`;
const SET_TRIGGER = new RegExp(LEAD + String.raw`(?:(?:поставь|заведи|установи|включи|запусти|сделай)\s+(?:мне\s+)?(?:таймер|будильник|напоминание)|таймер|будильник|напомни(?:ть)?(?:\s+мне)?|разбуди(?:\s+меня)?|(?:set|start)\s+(?:a\s+|an\s+|the\s+)?(?:timer|alarm|reminder)|timer|alarm|remind\s+me|wake\s+me(?:\s+up)?)(?![\p{L}\p{N}_])`, "u");
const CANCEL_TRIGGER = /^(?:отмени|удали|сбрось|выключи|останови|убери|cancel|stop|delete|clear|remove)\s+(?:(все|all)\s+)?(?:мои\s+|my\s+|the\s+)?(?:таймер|будильник|напоминани|timer|alarm|reminder)/u;
const LIST_TRIGGER = /^(?:сколько\s+(?:ещё|еще)?\s*осталось|какие\s+(?:у\s+меня\s+)?таймеры|мои\s+таймеры|покажи\s+таймеры|how\s+much\s+time\s+(?:is\s+)?left|list\s+(?:my\s+)?timers|my\s+timers|show\s+(?:my\s+)?timers)/u;

const NUMBER_WORDS = {
  одну: 1, одна: 1, один: 1, две: 2, два: 2, три: 3, четыре: 4, пять: 5, шесть: 6, семь: 7, восемь: 8, девять: 9,
  десять: 10, пятнадцать: 15, двадцать: 20, тридцать: 30, сорок: 40, пятьдесят: 50, пару: 2, пара: 2,
  one: 1, two: 2, three: 3, four: 4, five: 5, six: 6, seven: 7, eight: 8, nine: 9, ten: 10, fifteen: 15,
  twenty: 20, thirty: 30, forty: 40, fifty: 50, a: 1, an: 1,
};
// Fixed phrases first ("полчаса" would otherwise read as "час").
const PHRASES = [["полтора часа", 5400], ["полчаса", 1800], ["четверть часа", 900], ["half an hour", 1800],
  ["quarter of an hour", 900], ["an hour and a half", 5400]];
const END = String.raw`(?![\p{L}\p{N}_])`;
const UNIT = new RegExp(String.raw`(\d+(?:[.,]\d+)?)\s*(секунд[уы]?|сек\.?|с${END}|минут[уы]?|мин\.?|м${END}|час(?:а|ов)?|ч${END}|seconds?|secs?|s${END}|minutes?|mins?|m${END}|hours?|hrs?|h${END})`, "gu");
const BARE = new RegExp(String.raw`(?:через|in|for|на)\s+(минуту|час|секунду|a minute|an hour|a second)${END}`, "gu");
const CLOCK = new RegExp(String.raw`(?:^|(?<=\s))(?:в|at|на)\s*(\d{1,2})(?:[:.](\d{2}))?\s*(am|pm|утра|вечера|дня)?${END}`, "gu");
const FILLER = new Set(["через", "на", "в", "in", "for", "at", "to", "about", "that", "чтобы", "что", "о", "об", "про", "мне", "me", "and", "и"]);

const clean = (text) => String(text).toLowerCase().trim().replace(/^[\s\p{P}]+|[\s\p{P}]+$/gu, "");
const capital = (s) => s.charAt(0).toUpperCase() + s.slice(1);

/** "15:30", "at 3pm", "в 7 утра": today, or tomorrow if that time has passed. */
function clockTime(m, now) {
  let hour = Number(m[1]);
  const minute = m[2] !== undefined ? Number(m[2]) : 0, suffix = m[3] || "";
  // "в 5" without minutes or am/pm is too vague ("в 5 раз"?): only accept clear times.
  if (hour > 23 || minute > 59 || (m[2] === undefined && !suffix)) return null;
  if (["pm", "вечера", "дня"].includes(suffix) && hour < 12) hour += 12;
  if (["am", "утра"].includes(suffix) && hour === 12) hour = 0;
  const at = new Date(now);
  at.setHours(hour, minute, 0, 0);
  if (at <= now) at.setDate(at.getDate() + 1);
  return at;
}

/** What's left once the time is cut out: "выпить воды" from "через 20 минут выпить воды". */
function labelFrom(rest, spans) {
  let t = rest;
  for (const [start, end] of [...spans].sort((a, b) => b[0] - a[0])) t = t.slice(0, start) + " " + t.slice(end);
  const words = t.split(/[\s,]+/).filter(Boolean);
  while (words.length && FILLER.has(words[0])) words.shift();
  while (words.length && FILLER.has(words[words.length - 1])) words.pop();
  return words.join(" ");
}

/**
 * Reads a chat message. Returns null for anything that isn't a timer command, or
 * { type: "set", fireAt, label, duration } | { type: "needsHelp" } | { type: "cancel", all } | { type: "list" }.
 */
function parse(text, now = new Date()) {
  const s = clean(text);
  const cancel = s.match(CANCEL_TRIGGER);
  if (cancel) return { type: "cancel", all: !!cancel[1] };
  if (LIST_TRIGGER.test(s)) return { type: "list" };
  const trigger = s.match(SET_TRIGGER);
  if (!trigger) return null;
  let rest = s.slice(trigger[0].length);

  let seconds = 0;
  for (const [phrase, value] of PHRASES) {
    if (rest.includes(phrase)) { seconds += value; rest = rest.split(phrase).join(" "); }
  }
  rest = rest.split(" ").map((w) => (w in NUMBER_WORDS ? String(NUMBER_WORDS[w]) : w)).join(" ");
  const spans = [];
  for (const m of rest.matchAll(UNIT)) {
    const n = Number(m[1].replace(",", ".")), u = m[2];
    seconds += n * (u.startsWith("с") || u.startsWith("s") ? 1 : u.startsWith("ч") || u.startsWith("h") ? 3600 : 60);
    spans.push([m.index, m.index + m[0].length]);
  }
  for (const m of rest.matchAll(BARE)) {
    const w = m[1];
    seconds += w.includes("час") || w.includes("hour") ? 3600 : w.includes("мин") || w.includes("minute") ? 60 : 1;
    spans.push([m.index, m.index + m[0].length]);
  }

  let fireAt = null, duration = null;
  if (seconds > 0) {
    fireAt = new Date(now.getTime() + seconds * 1000);
    duration = seconds;
  } else {
    for (const m of rest.matchAll(CLOCK)) {
      const at = clockTime(m, now);
      if (at) { fireAt = at; spans.push([m.index, m.index + m[0].length]); break; }
    }
  }
  if (!fireAt) return { type: "needsHelp" };
  // The label was found in lowercase; take the same words from the original to keep its case.
  let label = labelFrom(rest, spans);
  const at = label ? String(text).toLowerCase().indexOf(label) : -1;
  if (at >= 0) label = String(text).slice(at, at + label.length);
  return { type: "set", fireAt, label: capital(label), duration };
}

const STOPWATCH_NOUN = String.raw`(?:секундомер[\p{L}]*|stopwatch)`;
const STOPWATCH_RULES = [
  ["pause", String.raw`(?:останови|стоп|пауза|поставь\s+на\s+паузу|приостанови|pause|stop)\s+(?:the\s+)?` + STOPWATCH_NOUN],
  ["resume", String.raw`(?:продолжи|возобнови|сними\s+с\s+паузы|resume|continue|unpause)\s+(?:the\s+)?` + STOPWATCH_NOUN],
  ["reset", String.raw`(?:сбрось|обнули|удали|убери|reset|clear|cancel)\s+(?:the\s+)?` + STOPWATCH_NOUN],
  ["show", String.raw`(?:сколько\s+прошло|сколько\s+на\s+секундомере|how\s+long\s+has\s+it\s+been|stopwatch\s+time)`],
  ["start", String.raw`(?:(?:запусти|включи|поставь|начни|заведи|start|run)\s+(?:a\s+|the\s+)?` + STOPWATCH_NOUN + "|"
    + STOPWATCH_NOUN + String.raw`|засеки(?:\s+время)?|time\s+me|start\s+timing)$`],
].map(([cmd, body]) => [cmd, new RegExp(LEAD + body, "u")]);

/** "start" | "pause" | "resume" | "reset" | "show" | null. */
function parseStopwatch(text) {
  const s = clean(text);
  for (const [cmd, re] of STOPWATCH_RULES) if (re.test(s)) return cmd;
  return null;
}

/** Instructions for Claude when we couldn't read a timer request ourselves. */
function helpPrompt(message, now = new Date()) {
  const tz = Intl.DateTimeFormat().resolvedOptions().timeZone;
  const off = -now.getTimezoneOffset(), sign = off >= 0 ? "+" : "-", abs = Math.abs(off);
  const local = new Date(now.getTime() + off * 60000).toISOString().slice(0, 19)
    + `${sign}${String(Math.floor(abs / 60)).padStart(2, "0")}:${String(abs % 60).padStart(2, "0")}`;
  return `Right now it is ${local} (local time zone ${tz}). `
    + "If the user's message below asks to set a timer, alarm or reminder, reply with exactly one line and nothing else: "
    + 'TIMER {"fire_at": "<ISO 8601 with offset>", "label": "<what to remind about, in the user\'s language, or empty>"} '
    + "If it is not such a request, answer it normally instead.\n\n"
    + `User's message: ${message}`;
}

/** Reads Claude's `TIMER {...}` line; null if the answer is something else. */
function parseHelp(answer, now = new Date()) {
  const t = String(answer).trim();
  if (!t.startsWith("TIMER")) return null;
  try {
    const j = JSON.parse(t.slice(t.indexOf("{")));
    const at = new Date(j.fire_at);
    if (Number.isNaN(at.getTime()) || at <= now) return null;
    return { fireAt: at, label: typeof j.label === "string" ? j.label : "" };
  } catch {
    return null;
  }
}

// MARK: Formatting

const pad = (n) => String(n).padStart(2, "0");

/** Badge countdown: "9:59", "59:59", "1ч05" / "1h05". */
function compact(seconds, lang) {
  const s = Math.max(0, Math.ceil(seconds));
  if (s < 3600) return `${Math.floor(s / 60)}:${pad(s % 60)}`;
  return `${Math.floor(s / 3600)}${lang === "ru" ? "ч" : "h"}${pad(Math.floor(s / 60) % 60)}`;
}

/** "9:59", "1:05:00". */
function left(seconds) {
  const s = Math.max(0, Math.ceil(seconds));
  return s >= 3600 ? `${Math.floor(s / 3600)}:${pad(Math.floor(s / 60) % 60)}:${pad(s % 60)}` : `${Math.floor(s / 60)}:${pad(s % 60)}`;
}

/** Stopwatch: "1:23", "1:02:03", optionally with tenths. */
function elapsed(seconds, tenths = false) {
  const t = Math.max(0, seconds), s = Math.floor(t);
  const base = s >= 3600 ? `${Math.floor(s / 3600)}:${pad(Math.floor(s / 60) % 60)}:${pad(s % 60)}` : `${Math.floor(s / 60)}:${pad(s % 60)}`;
  return tenths ? `${base}.${Math.floor(t * 10) % 10}` : base;
}

/** "10 мин", "1 ч 30 мин", "45 сек". */
function length(seconds, lang) {
  const s = Math.round(seconds), ru = lang === "ru";
  const h = Math.floor(s / 3600), m = Math.floor(s / 60) % 60, sec = s % 60, parts = [];
  if (h) parts.push(`${h} ${ru ? "ч" : "h"}`);
  if (m) parts.push(`${m} ${ru ? "мин" : "min"}`);
  if (sec && !h) parts.push(`${sec} ${ru ? "сек" : "s"}`);
  return parts.join(" ") || (ru ? "0 сек" : "0 s");
}

function clock(date, lang, now = new Date()) {
  const d = new Date(date), sameDay = d.toDateString() === now.toDateString();
  const time = `${pad(d.getHours())}:${pad(d.getMinutes())}`;
  if (sameDay) return time;
  return `${d.toLocaleDateString(lang === "ru" ? "ru-RU" : "en-US", { day: "numeric", month: "short" })}, ${time}`;
}

// MARK: Store

/** Timers (soonest first) and the stopwatch, saved to <userData>/timers.json so they survive restarts. */
class TimerStore {
  constructor(dir) {
    this.file = path.join(dir, "timers.json");
    let saved = {};
    try { saved = JSON.parse(fs.readFileSync(this.file, "utf8")); } catch {}
    this.timers = Array.isArray(saved.timers) ? saved.timers.filter((t) => t && typeof t.fireAt === "number") : [];
    this.stopwatch = saved.stopwatch && typeof saved.stopwatch.accumulated === "number" ? saved.stopwatch : null;
  }

  add(fireAt, label, duration) {
    const t = { id: crypto.randomUUID(), label: label || "", fireAt: +fireAt, duration: duration || null };
    this.timers.push(t);
    this.timers.sort((a, b) => a.fireAt - b.fireAt);
    this.save();
    return t;
  }

  remove(id) { this.timers = this.timers.filter((t) => t.id !== id); this.save(); }

  /** Timers whose time has come, taken off the list. */
  popDue(now = Date.now()) {
    const due = this.timers.filter((t) => t.fireAt <= now);
    if (due.length) { this.timers = this.timers.filter((t) => t.fireAt > now); this.save(); }
    return due;
  }

  stopwatchElapsed(now = Date.now()) {
    const sw = this.stopwatch;
    return sw ? sw.accumulated + (sw.startedAt ? (now - sw.startedAt) / 1000 : 0) : 0;
  }

  setStopwatch(sw) { this.stopwatch = sw; this.save(); }

  save() {
    try { fs.writeFileSync(this.file, JSON.stringify({ timers: this.timers, stopwatch: this.stopwatch })); } catch {}
  }
}

module.exports = { parse, parseStopwatch, helpPrompt, parseHelp, compact, left, elapsed, length, clock, TimerStore };
