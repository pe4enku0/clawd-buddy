// Getting a dropped file ready for claude -p: what we read, what we cut, what we refuse.
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const files = require("../src/files.js");

const dir = fs.mkdtempSync(path.join(os.tmpdir(), "clawd-files-"));
test.after(() => fs.rmSync(dir, { recursive: true, force: true }));
const put = (name, data) => { const p = path.join(dir, name); fs.writeFileSync(p, data); return p; };

test("kind: text, code, unknown text extensions, PDFs and images are read; binaries and folders aren't", () => {
  assert.equal(files.kind(put("notes.md", "# hi")), "text");
  assert.equal(files.kind(put("App.vue", "<template/>")), "text");
  assert.equal(files.kind(put("data.weird", "plain words")), "text");
  assert.equal(files.kind(put("doc.pdf", "%PDF-1.4")), "pdf");
  assert.equal(files.kind(put("shot.PNG", "x")), "image");
  assert.equal(files.kind(put("blob.bin", Buffer.from([0, 1, 2, 3]))), null);
  assert.equal(files.kind(dir), null);
  assert.equal(files.kind(path.join(dir, "missing.txt")), null);
});

test("prepare: a big text file is cut at a line break and says so", () => {
  const big = put("big.log", Array.from({ length: 5000 }, (_, i) => `line ${i} ${"x".repeat(60)}`).join("\n"));
  const f = files.prepare(big, { lang: "ru" });
  const copied = fs.readFileSync(f.path, "utf8");
  assert.ok(copied.length <= files.TEXT_LIMIT);
  assert.ok(copied.endsWith("x"), "ends on a whole line");
  assert.match(f.note, /^Файл большой \(\d.* КБ\), читаю только начало$/);
  assert.match(f.hint, /only the beginning/);
  files.discard(f);
  assert.equal(fs.existsSync(f.path), false);
});

test("prepare: a small file is copied whole, under its own name", () => {
  const f = files.prepare(put("main.rs", "fn main() {}"));
  assert.equal(f.name, "main.rs");
  assert.equal(fs.readFileSync(f.path, "utf8"), "fn main() {}");
  assert.equal(f.note, null);
  files.discard(f);
});

test("prepare: a long PDF is limited to its first pages", () => {
  const pdf = put("long.pdf", "%PDF-1.4\n" + "<< /Type /Page >>\n".repeat(25) + "<< /Type /Pages >>");
  assert.equal(files.pdfPages(pdf), 25);
  const f = files.prepare(pdf, { lang: "en" });
  assert.equal(f.note, "25-page PDF, reading the first 10");
  assert.match(f.hint, /pages 1-10/);
  files.discard(f);
});

test("prepare: images go through the resizer and come out as JPEG", () => {
  let asked;
  const f = files.prepare(put("photo.png", "fake"), { resizeImage: (p, max) => { asked = max; return Buffer.from("jpeg!"); } });
  assert.equal(asked, 1600);
  assert.equal(f.name, "photo.jpg");
  assert.equal(fs.readFileSync(f.path, "utf8"), "jpeg!");
  files.discard(f);
});

test("prepare: refuses what it can't read", () => {
  assert.equal(files.prepare(put("blob2.bin", Buffer.from([0, 0, 0]))), null);
  assert.equal(files.prepare(put("bad.png", "x"), { resizeImage: () => Buffer.alloc(0) }), null);
});
