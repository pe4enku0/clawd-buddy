#!/bin/bash
# Builds the app, installs it to ~/Applications and wires it into Claude Code hooks.
set -euo pipefail
cd "$(dirname "$0")"

# macOS does not ship jq, and settings.json has to be edited without losing anybody else's hooks.
command -v jq >/dev/null 2>&1 || {
  echo "jq is required to edit ~/.claude/settings.json. Install it with: brew install jq" >&2
  exit 1
}

./build.sh

DEST="$HOME/Applications/ClawdBuddy.app"
pkill -x ClawdBuddy 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R build/ClawdBuddy.app "$DEST"

SETTINGS="$HOME/.claude/settings.json"
CMD="\"$DEST/Contents/MacOS/ClawdBuddy\" hook"
mkdir -p "$HOME/.claude"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
[ -f "$SETTINGS.bak-clawdbuddy" ] || cp "$SETTINGS" "$SETTINGS.bak-clawdbuddy"
OUT=$(mktemp)

# Replaces our entries and keeps everybody else's hooks, including the ones that share a group
# with ours (see hooks.jq, and test-hooks.sh for the cases). Written to a temp file first, so
# settings.json survives a filter that cannot parse it.
jq --arg mode install --arg cmd "$CMD" -f hooks.jq "$SETTINGS" > "$OUT" \
  || { rm -f "$OUT"; echo "Could not update $SETTINGS, hooks not added" >&2; exit 1; }
mv "$OUT" "$SETTINGS"

open "$DEST"
echo "Installed to $DEST"
echo "Hooks added to $SETTINGS (backup: $SETTINGS.bak-clawdbuddy)"
