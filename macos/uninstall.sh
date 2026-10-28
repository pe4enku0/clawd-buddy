#!/bin/bash
# Removes the app and its Claude Code hooks.
set -euo pipefail
cd "$(dirname "$0")"

SETTINGS="$HOME/.claude/settings.json"
pkill -x ClawdBuddy 2>/dev/null || true
rm -rf "$HOME/Applications/ClawdBuddy.app"

if [ -f "$SETTINGS" ]; then
  # The app is already gone, so a missing jq would leave hooks pointing at nothing. Say so loudly
  # instead of exiting quietly.
  command -v jq >/dev/null 2>&1 || {
    echo "jq is required to clean up $SETTINGS. Install it with: brew install jq" >&2
    echo "The app is removed, but its hooks are still in $SETTINGS." >&2
    exit 1
  }
  tmp=$(mktemp)
  jq --arg mode uninstall -f hooks.jq "$SETTINGS" > "$tmp" \
    || { rm -f "$tmp"; echo "Could not update $SETTINGS; remove the ClawdBuddy hooks by hand" >&2; exit 1; }
  mv "$tmp" "$SETTINGS"
fi
echo "Clawd Buddy removed."
