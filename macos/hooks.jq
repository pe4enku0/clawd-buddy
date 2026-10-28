# Claude Code settings.json surgery, shared by install.sh and uninstall.sh:
#
#   jq --arg mode install   --arg cmd "<app>/Contents/MacOS/ClawdBuddy hook" -f hooks.jq settings.json
#   jq --arg mode uninstall -f hooks.jq settings.json
#
# Our entries are recognised by "ClawdBuddy" inside the command, so an install path from an older
# version gets cleaned up as well. Filtering happens *inside* a hook group: a group that also holds
# somebody else's hook keeps that hook, because deleting a stranger's hook is worse than leaving
# ours behind. The Electron port has always worked this way (windows/src/hooks.js).

def is_ours: (.command // "") | contains("ClawdBuddy");

def strip_ours:
  if (.hooks | type) != "object" then . else
    .hooks |= (
      with_entries(
        if (.value | type) != "array" then . else
          .value |= (
            map(
              if ((.hooks // []) | any(is_ours))
              then .hooks |= map(select(is_ours | not))
              else .
              end
            )
            | map(select((.hooks // []) | length > 0))
          )
        end
      )
      | with_entries(select((.value | length) > 0))
    )
    | if (.hooks | length) == 0 then del(.hooks) else . end
  end;

def our_hooks($cmd): {hooks: [{type: "command", command: $cmd, async: true, timeout: 5}]};

strip_ours
| if $mode == "install" then
    .hooks //= {}
    | reduce ("SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUseFailure", "Stop", "Notification") as $e (.;
        .hooks[$e] = ((.hooks[$e] // []) + [
          if ($e == "PreToolUse" or $e == "PostToolUseFailure")
          then {matcher: "*"} + our_hooks($cmd)
          else our_hooks($cmd)
          end
        ]))
  else .
  end
