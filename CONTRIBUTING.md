# Contributing

Thanks for poking around. Clawd Buddy is a small project with strong opinions — matching them is most of the review.

## Layout

| Path | What |
|---|---|
| `macos/` | native Swift/AppKit + SwiftUI app, built by `build.sh` into `build/ClawdBuddy.app` |
| `windows/` | Electron app; `src/main.js` owns the window, tray and hook server, `src/hooks.js` owns `settings.json` |
| `windows/src/renderer/` | canvas sprite, moods, phrases and the settings page |
| `.github/workflows/build.yml` | tests on every pull request; builds both apps on `main`; publishes on a `v*` tag |

## Running it

```bash
cd windows && npm install && npm start     # Windows, macOS and Linux (dev)
cd macos && ./build.sh                     # macOS 13+, needs Xcode Command Line Tools
```

`npm start` registers hooks only when you click **Connect** in Settings, and the app answers on `127.0.0.1:47321`, so a dev instance and an installed copy fight over the port. Quit one before starting the other.

## Tests

```bash
cd windows && npm test
```

`src/hooks.js` rewrites `~/.claude/settings.json`, which makes it the one file where a mistake costs a user their config. It is covered by `windows/test/` and the runner points `HOME` at a temp directory. If you touch normalisation or the install/uninstall path, add a test.

The Swift app has no test target yet; `./macos/build.sh` is the check, and CI builds it on every pull request.

## House rules

- **No runtime dependencies.** Native modules from the standard library only; Node built-ins only. A PR that adds a package needs a very good reason.
- **Comments explain why, not what.** Every non-obvious decision in this repo has a sentence above it — see `HookBridge.swift` or `main.js`.
- **Two languages, always.** Every user-facing line exists in English and Russian (`strings.js`, `Strings.swift`). New phrase keys need both, and `%d` placeholders for the edit streak.
- **One PR, one thing.** A fix plus a refactor plus a new animation is three PRs.
- **Commit messages:** imperative, sentence case, no prefixes — `Add Windows version`, `Harden the hook channel`, `Fix hooks without a token`.
- **Screenshots for anything visual.** The crab is the product; a diff does not show whether it looks right.
- **Don't reformat code you are not changing.** It hides the real diff.

## Reporting a bug

Include the OS and its version, the app version (Settings footer), what Claude Code was doing at the time, and whether Settings says **Connected**. If the hooks look installed but nothing happens, say which port the app picked up and whether another copy is running.
