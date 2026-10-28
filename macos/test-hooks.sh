#!/bin/bash
# Tests for hooks.jq, the filter install.sh and uninstall.sh run against ~/.claude/settings.json.
#
#   ./test-hooks.sh
#
# Needs jq and nothing else, so it runs on any machine — including the Linux box of somebody
# reviewing a macOS change. The important case is the third one: a hook group often holds both
# our entry and somebody else's, and a filter that drops the whole group silently deletes it.
set -euo pipefail
cd "$(dirname "$0")"

command -v jq >/dev/null 2>&1 || { echo "jq is required to run these tests" >&2; exit 1; }

CMD="/Users/me/Applications/ClawdBuddy.app/Contents/MacOS/ClawdBuddy hook"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failures=0

apply() { # mode, file
  jq --arg mode "$1" --arg cmd "$CMD" -f hooks.jq "$2"
}

check() { # name, actual, expected
  if [ "$2" = "$3" ]; then
    echo "ok: $1"
  else
    echo "FAIL: $1" >&2
    echo "  expected: $3" >&2
    echo "  actual:   $2" >&2
    failures=$((failures + 1))
  fi
}

query() { # json, filter
  printf '%s' "$1" | jq -r "$2"
}

# 1. A bare settings file gets all six events, and only tool events carry a matcher.
printf '{}' > "$tmp/empty.json"
installed=$(apply install "$tmp/empty.json")
check "install wires every event" \
  "$(query "$installed" '.hooks | keys | sort | join(",")')" \
  "Notification,PostToolUseFailure,PreToolUse,SessionStart,Stop,UserPromptSubmit"
check "install sets a matcher on tool events" \
  "$(query "$installed" '.hooks.PreToolUse[0].matcher')" "*"
check "install leaves lifecycle events without a matcher" \
  "$(query "$installed" '.hooks.Stop[0] | has("matcher")')" "false"
check "install points at the app binary" \
  "$(query "$installed" '.hooks.Stop[0].hooks[0].command')" "$CMD"
check "install keeps the hook in the background" \
  "$(query "$installed" '.hooks.Stop[0].hooks[0].async')" "true"

# 2. Installing twice must not append a second copy.
printf '%s' "$installed" > "$tmp/installed.json"
twice=$(apply install "$tmp/installed.json")
check "install is idempotent" "$(query "$twice" '.hooks.Stop | length')" "1"

# 3. A group holding both our hook and somebody else's keeps the stranger's hook.
cat > "$tmp/mixed.json" <<'JSON'
{
  "hooks": {
    "Stop": [
      { "hooks": [
        { "type": "command", "command": "my-notifier --ping" },
        { "type": "command", "command": "OLD/ClawdBuddy.app/Contents/MacOS/ClawdBuddy hook" }
      ] }
    ]
  }
}
JSON
mixed=$(apply install "$tmp/mixed.json")
check "install keeps a foreign hook from the same group" \
  "$(query "$mixed" '.hooks.Stop | map(.hooks[].command) | map(select(contains("my-notifier"))) | length')" "1"
check "install replaces the old entry instead of adding a third" \
  "$(query "$mixed" '.hooks.Stop | map(.hooks | length) | add')" "2"

# 4. Uninstall removes our hooks, prunes what it emptied, and touches nothing else.
cat > "$tmp/foreign-only.json" <<'JSON'
{
  "permissions": { "allow": ["Bash"] },
  "hooks": { "Stop": [{ "hooks": [{ "type": "command", "command": "my-notifier --ping" }] }] }
}
JSON
after_install=$(apply install "$tmp/foreign-only.json")
printf '%s' "$after_install" > "$tmp/round-trip.json"
removed=$(apply uninstall "$tmp/round-trip.json")
check "uninstall leaves only foreign hooks" \
  "$(query "$removed" '.hooks | keys | join(",")')" "Stop"
check "uninstall keeps the foreign command" \
  "$(query "$removed" '.hooks.Stop[0].hooks[0].command')" "my-notifier --ping"
check "uninstall keeps unrelated settings" \
  "$(query "$removed" '.permissions.allow[0]')" "Bash"

printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"%s"}]}]}}' "$CMD" > "$tmp/only-ours.json"
cleaned=$(apply uninstall "$tmp/only-ours.json")
check "uninstall drops the hooks key when nothing is left" \
  "$(query "$cleaned" 'has("hooks")')" "false"

# 5. Anything we do not understand is left exactly as it was.
printf '{"hooks":{"Stop":"nonsense"},"other":1}' > "$tmp/odd.json"
odd=$(apply uninstall "$tmp/odd.json")
check "uninstall survives a malformed hook list" \
  "$(query "$odd" '(.hooks.Stop == "nonsense") and (.other == 1)')" "true"

if [ "$failures" -ne 0 ]; then
  echo "$failures test(s) failed" >&2
  exit 1
fi
echo "all hook filter tests passed"
