#!/usr/bin/env node
// Fails when a release tag disagrees with the version the apps actually report.
//
//   node scripts/check-version.mjs v1.2.0
//
// The release job publishes whatever the tag says while the installer name, the settings footer and
// the macOS bundle all come from three different files. This is the one place that compares them.
import { readFileSync } from "node:fs";

const tag = (process.argv[2] ?? "").replace(/^v/, "");
if (!/^\d+\.\d+\.\d+$/.test(tag)) {
  console.error(`usage: node scripts/check-version.mjs v1.2.3 (got "${process.argv[2] ?? ""}")`);
  process.exit(2);
}

const pkg = JSON.parse(readFileSync(new URL("../windows/package.json", import.meta.url), "utf8")).version;
const plist = readFileSync(new URL("../macos/Info.plist", import.meta.url), "utf8")
  .match(/<key>CFBundleShortVersionString<\/key>\s*<string>([^<]+)<\/string>/)?.[1];

if (!plist) {
  console.error("macos/Info.plist has no CFBundleShortVersionString");
  process.exit(1);
}

// The macOS bundle may say "1.1" where package.json says "1.1.0"; both mean the same release.
const normalise = (v) => v.split(".").concat(["0", "0"]).slice(0, 3).join(".");

if (normalise(tag) !== normalise(pkg) || normalise(tag) !== normalise(plist)) {
  console.error(`Tag ${process.argv[2]} does not match the apps:`);
  console.error(`  windows/package.json         ${pkg}`);
  console.error(`  macos/Info.plist             ${plist}`);
  process.exit(1);
}

console.log(`version ok: ${tag} (package.json ${pkg}, Info.plist ${plist})`);
