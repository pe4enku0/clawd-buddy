// Timer and stopwatch phrases: the same cases as the Mac parser, so both apps understand the same things.
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const T = require("../src/timers.js");

const now = new Date(2026, 9, 29, 14, 0, 0);  // 29 Oct 2026, 14:00 local
const at = (h, m, dayOffset = 0) => new Date(2026, 9, 29 + dayOffset, h, m, 0).getTime();
const set = (text) => { const r = T.parse(text, now); assert.equal(r?.type, "set", text); return r; };
const mins = (r) => (r.fireAt - now) / 60000;

test("countdowns in Russian and English", () => {
  for (const [text, minutes] of [["таймер на 10 минут", 10], ["поставь таймер на полчаса", 30], ["Таймер 5 мин", 5],
    ["таймер на 1 час 30 минут", 90], ["таймер на пять минут", 5], ["Клод, поставь таймер на 90 секунд", 1.5],
    ["таймер на полтора часа", 90], ["set a timer for 10 minutes", 10], ["timer 45 sec", 0.75],
    ["set a timer for half an hour", 30]]) {
    const r = set(text);
    assert.equal(mins(r), minutes, text);
    assert.equal(r.label, "", text);
  }
});

test("reminders keep what to remind about, with its original case", () => {
  assert.deepEqual([mins(set("напомни через 20 минут выпить воды")), set("напомни через 20 минут выпить воды").label], [20, "Выпить воды"]);
  assert.equal(set("напомни мне через час позвонить маме").label, "Позвонить маме");
  assert.equal(set("напомни через пару минут проверить сборку").label, "Проверить сборку");
  assert.equal(set("remind me in 15 minutes to stretch").label, "Stretch");
  assert.equal(set("remind me at 3pm to call Bob").label, "Call Bob");
});

test("clock times are today, or tomorrow once passed", () => {
  assert.equal(+set("напомни в 15:30 созвон").fireAt, at(15, 30));
  assert.equal(+set("напомни в 13:00 обед").fireAt, at(13, 0, 1));
  assert.equal(+set("разбуди в 7 утра").fireAt, at(7, 0, 1));
  assert.equal(+set("remind me at 3pm to call Bob").fireAt, at(15, 0));
  assert.equal(set("напомни в 15:30 созвон").duration, null);
});

test("other commands, and what Claude has to read", () => {
  assert.deepEqual(T.parse("отмени таймер", now), { type: "cancel", all: false });
  assert.deepEqual(T.parse("отмени все таймеры", now), { type: "cancel", all: true });
  assert.deepEqual(T.parse("cancel the timer", now), { type: "cancel", all: false });
  assert.deepEqual(T.parse("сколько осталось?", now), { type: "list" });
  assert.deepEqual(T.parse("мои таймеры", now), { type: "list" });
  assert.deepEqual(T.parse("напомни послезавтра утром про дедлайн", now), { type: "needsHelp" });
});

test("questions about timers stay questions", () => {
  for (const q of ["как сделать таймер в js на 5 секунд?", "что такое setTimeout 10 секунд",
    "через 5 минут начнётся урок, что почитать?"]) assert.equal(T.parse(q, now), null, q);
});

test("stopwatch commands", () => {
  const cases = {
    start: ["запусти секундомер", "секундомер", "засеки время", "засеки", "Клод, включи секундомер", "start a stopwatch", "time me"],
    pause: ["останови секундомер", "пауза секундомера", "stop the stopwatch"],
    resume: ["продолжи секундомер", "resume stopwatch"],
    reset: ["сбрось секундомер", "reset the stopwatch"],
    show: ["сколько прошло?", "how long has it been"],
  };
  for (const [cmd, phrases] of Object.entries(cases)) for (const p of phrases) assert.equal(T.parseStopwatch(p), cmd, p);
  for (const q of ["как сделать секундомер на js?", "секундомер в swiftui как?", "засеки, сколько займёт сборка", "отмени таймер"]) {
    assert.equal(T.parseStopwatch(q), null, q);
  }
});

test("Claude's TIMER line becomes a timer; anything else stays an answer", () => {
  const r = T.parseHelp('TIMER {"fire_at": "2026-10-31T09:00:00+01:00", "label": "Дедлайн"}', now);
  assert.equal(r.label, "Дедлайн");
  assert.equal(r.fireAt.toISOString(), "2026-10-31T08:00:00.000Z");
  assert.equal(T.parseHelp("Замыкание — это функция…", now), null);
  assert.equal(T.parseHelp('TIMER {"fire_at": "2020-01-01T00:00:00Z"}', now), null, "past times are refused");
  assert.match(T.helpPrompt("x", now), /TIMER \{"fire_at"/);
});

test("formatting", () => {
  assert.deepEqual([T.compact(599, "ru"), T.compact(3599, "ru"), T.compact(3900, "ru"), T.compact(3900, "en")], ["9:59", "59:59", "1ч05", "1h05"]);
  assert.deepEqual([T.left(581), T.left(5400)], ["9:41", "1:30:00"]);
  assert.deepEqual([T.elapsed(83), T.elapsed(754.3, true)], ["1:23", "12:34.3"]);
  assert.deepEqual([T.length(600, "ru"), T.length(5400, "ru"), T.length(90, "en")], ["10 мин", "1 ч 30 мин", "1 min 30 s"]);
});

test("the store keeps timers in order across restarts and hands out the due ones once", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "clawd-timers-"));
  const s = new T.TimerStore(dir);
  s.add(new Date(5000), "later", 5);
  s.add(new Date(1000), "", 1);
  s.setStopwatch({ accumulated: 10, startedAt: null });
  const again = new T.TimerStore(dir);
  assert.deepEqual(again.timers.map((t) => t.label), ["", "later"]);
  assert.equal(again.stopwatchElapsed(), 10);
  assert.deepEqual(again.popDue(2000).map((t) => t.fireAt), [1000]);
  assert.deepEqual(again.popDue(2000), []);
  fs.rmSync(dir, { recursive: true, force: true });
});
