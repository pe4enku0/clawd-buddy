// A file dropped on the crab, copied into a private temp folder in a form `claude -p` can Read.
// Port of macos/Sources/FileDrop.swift.
const fs = require("fs");
const os = require("os");
const path = require("path");

const TEXT_LIMIT = 200_000;
const PDF_PAGE_LIMIT = 10;
const IMAGE_PIXELS = 1600;
const IMAGE_EXT = new Set(["png", "jpg", "jpeg", "gif", "webp"]);
const TEXT_EXT = new Set([
  "txt", "md", "markdown", "rst", "log", "csv", "tsv", "json", "jsonc", "yaml", "yml", "toml", "ini", "cfg", "conf", "xml",
  "html", "htm", "css", "scss", "less", "js", "mjs", "cjs", "jsx", "ts", "tsx", "vue", "svelte", "py", "rb", "go", "rs",
  "java", "kt", "kts", "swift", "c", "h", "cpp", "hpp", "cc", "cs", "php", "sh", "bash", "zsh", "ps1", "bat", "cmd",
  "sql", "graphql", "lua", "r", "dart", "scala", "ex", "exs", "erl", "hs", "ml", "clj", "gradle", "dockerfile", "env",
  "gitignore", "editorconfig", "tex", "srt",
]);
const PREFIX = "ClawdFile-";

const ext = (p) => path.extname(p).slice(1).toLowerCase();

/** Valid UTF-8 without NUL bytes in the first 8 KB reads as text. */
function looksLikeText(file) {
  let fd;
  try {
    fd = fs.openSync(file, "r");
    const buf = Buffer.alloc(8192);
    const n = fs.readSync(fd, buf, 0, buf.length, 0);
    const head = buf.subarray(0, n);
    if (head.includes(0)) return false;
    new TextDecoder("utf-8", { fatal: true }).decode(head, { stream: true });
    return true;
  } catch {
    return false;
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
  }
}

/** "text" | "pdf" | "image" | null (folders and anything we don't read). */
function kind(file) {
  let st;
  try { st = fs.statSync(file); } catch { return null; }
  if (!st.isFile()) return null;
  const e = ext(file);
  if (IMAGE_EXT.has(e)) return "image";
  if (e === "pdf") return "pdf";
  if (TEXT_EXT.has(e) || TEXT_EXT.has(path.basename(file).toLowerCase())) return "text";
  return looksLikeText(file) ? "text" : null;
}

/** Page count from the raw PDF (good enough to know a long one); 0 if it can't tell. */
function pdfPages(file) {
  try {
    const raw = fs.readFileSync(file).toString("latin1");
    return (raw.match(/\/Type\s*\/Page(?![s\w])/g) || []).length;
  } catch {
    return 0;
  }
}

function sizeText(bytes, lang) {
  const units = lang === "ru" ? ["Б", "КБ", "МБ", "ГБ"] : ["B", "KB", "MB", "GB"];
  let n = bytes, i = 0;
  while (n >= 1000 && i < units.length - 1) { n /= 1000; i++; }
  return `${i === 0 ? n : n.toFixed(n < 10 ? 1 : 0)} ${units[i]}`.replace(".", lang === "ru" ? "," : ".");
}

/**
 * Makes the temp copy: { path, name, note, hint } or null if it isn't something we read.
 * `resizeImage(src, maxPixels)` returns JPEG bytes (Electron's nativeImage in the app).
 */
function prepare(file, { lang = "en", resizeImage = null } = {}) {
  const k = kind(file);
  if (!k) return null;
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), PREFIX));
  const name = path.basename(file);
  const ru = lang === "ru";
  try {
    if (k === "text") {
      const size = fs.statSync(file).size;
      let data = Buffer.alloc(Math.min(size, TEXT_LIMIT + 1));
      const fd = fs.openSync(file, "r");
      try { fs.readSync(fd, data, 0, data.length, 0); } finally { fs.closeSync(fd); }
      let note = null, hint = "";
      if (size > TEXT_LIMIT) {
        data = data.subarray(0, TEXT_LIMIT);
        // Cut at the last line break so we don't hand over half a line or half a character.
        const nl = data.lastIndexOf(0x0a);
        if (nl > 0) data = data.subarray(0, nl);
        note = ru ? `Файл большой (${sizeText(size, lang)}), читаю только начало` : `Big file (${sizeText(size, lang)}), reading only the beginning`;
        hint = " This is only the beginning of a larger file; say so if it matters.";
      }
      const out = path.join(dir, name);
      fs.writeFileSync(out, data);
      return { path: out, name, note, hint };
    }
    if (k === "pdf") {
      const out = path.join(dir, name);
      fs.copyFileSync(file, out);
      const pages = pdfPages(file);
      if (pages <= PDF_PAGE_LIMIT) return { path: out, name, note: null, hint: "" };
      return {
        path: out, name,
        note: ru ? `В PDF ${pages} стр., читаю первые ${PDF_PAGE_LIMIT}` : `${pages}-page PDF, reading the first ${PDF_PAGE_LIMIT}`,
        hint: ` It has ${pages} pages: read only pages 1-${PDF_PAGE_LIMIT} (Read's pages parameter) and say it's a partial read.`,
      };
    }
    // Image: a downscaled JPEG is plenty for reading and quick to send.
    const jpgName = path.basename(name, path.extname(name)) + ".jpg";
    const out = path.join(dir, jpgName);
    const bytes = resizeImage ? resizeImage(file, IMAGE_PIXELS) : fs.readFileSync(file);
    if (!bytes || !bytes.length) throw new Error("unreadable image");
    fs.writeFileSync(resizeImage ? out : path.join(dir, name), bytes);
    return { path: resizeImage ? out : path.join(dir, name), name: resizeImage ? jpgName : name, note: null, hint: "" };
  } catch {
    discard({ path: path.join(dir, "x") });
    return null;
  }
}

function discard(f) {
  if (f) try { fs.rmSync(path.dirname(f.path), { recursive: true, force: true }); } catch {}
}

/** Leftovers (dropped files, screenshots) from a run that quit mid-chat. */
function cleanUp() {
  const tmp = os.tmpdir();
  for (const n of (() => { try { return fs.readdirSync(tmp); } catch { return []; } })()) {
    if (n.startsWith(PREFIX) || n.startsWith(SCREEN_PREFIX)) try { fs.rmSync(path.join(tmp, n), { recursive: true, force: true }); } catch {}
  }
}

const SCREEN_PREFIX = "ClawdScreen-";

/** Saves screenshot JPEG bytes where only this chat will find them; returns the path. */
function saveScreenshot(bytes) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), SCREEN_PREFIX));
  const file = path.join(dir, "screen.jpg");
  fs.writeFileSync(file, bytes);
  return file;
}

/**
 * Does this chat message ask about the screen? Whole words only, so "экранировать" (to escape)
 * or "SwiftUI screen" don't grab it. Same rule as macos/Sources/ScreenGrab.swift.
 */
function mentionsScreen(text) {
  return /(?<![\p{L}\p{N}_])экран(?:е|а|у|ом)?(?![\p{L}\p{N}_])|(?<![\p{L}\p{N}_])скрин|(?<![\p{L}\p{N}_])что (?:ты )?видишь|\b(?:my|the|on) screen\b|\bscreenshot|\bwhat (?:do )?you see\b/iu.test(String(text));
}

module.exports = { kind, prepare, discard, cleanUp, pdfPages, sizeText, saveScreenshot, mentionsScreen, TEXT_LIMIT };
