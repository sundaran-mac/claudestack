#!/bin/bash
# stack-hook.sh on Linux, with fake input in a temporary HOME. Usage: win/tests/hook-test.sh
set -uo pipefail
cd "$(dirname "$0")"
hook="$(cd ../.. && pwd)/stack-hook.sh"
h=$(mktemp -d); trap 'rm -rf "$h"' EXIT
fail=0
ok() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
ev() { # event json, extra env
  printf '%s' "$1" | env HOME="$h" TMUX="/tmp/tmux-1000/claudestack,123,0" TMUX_PANE="%7" CS_TAB="cs-42" CS_TERM="WindowsTerminal" bash "$hook"
}
f="$h/.claude/stack/sessions/s1.json"
out=$(ev '{"hook_event_name":"SessionStart","session_id":"s1","cwd":"/tmp/proj","source":"startup","transcript_path":"/tmp/t.jsonl"}'); code=$?
ok "prints nothing and exits 0" '[ -z "$out" ] && [ $code -eq 0 ]'
ok "session file written" '[ -f "$f" ]'
ok "status Ready" '[ "$(jq -r ".status+\" \"+.reason" "$f")" = "waiting Ready" ]'
ok "tmux pane and socket saved" '[ "$(jq -r ".tmux_pane+\" \"+.tmux_socket" "$f")" = "%7 /tmp/tmux-1000/claudestack" ]'
ok "tab tag and outer terminal saved" '[ "$(jq -r ".cs_tab+\" \"+.term" "$f")" = "cs-42 WindowsTerminal" ]'
ev '{"hook_event_name":"UserPromptSubmit","session_id":"s1","cwd":"/tmp/proj","prompt":"Fix   the\nbug"}' >/dev/null
ok "running with the prompt" '[ "$(jq -r ".status+\"|\"+.prompt" "$f")" = "running|Fix the bug" ]'
ev '{"hook_event_name":"PreToolUse","session_id":"s1","tool_name":"AskUserQuestion","tool_input":{}}' >/dev/null
ok "question needs you" '[ "$(jq -r ".status+\" \"+.reason" "$f")" = "needs_input Question" ]'
ev '{"hook_event_name":"PermissionRequest","session_id":"s1","tool_name":"Bash","tool_input":{"command":"rm -rf build"}}' >/dev/null
ok "permission keeps the command" '[ "$(jq -r ".pending_tool+\": \"+.pending_detail" "$f")" = "Bash: rm -rf build" ]'
ev '{"hook_event_name":"Stop","session_id":"s1"}' >/dev/null
ok "done" '[ "$(jq -r ".status+\" \"+.reason" "$f")" = "waiting Done" ]'
ok "day log written" '[ "$(wc -l < "$h/.claude/stack/days/$(date +%F).jsonl")" -eq 2 ]'
# A lock left over from a killed hook (older than 5 s) is cleared, so the write still happens.
mkdir "$f.lock"; touch -d '1 minute ago' "$f.lock"
ev '{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"after lock"}' >/dev/null
ok "stale lock cleared" '[ "$(jq -r .prompt "$f")" = "after lock" ] && [ ! -d "$f.lock" ]'
# Parallel hooks do not corrupt the file.
for i in $(seq 1 20); do ev '{"hook_event_name":"PreToolUse","session_id":"s1","tool_name":"Read","tool_input":{"file_path":"/x"}}' >/dev/null & done; wait
ok "parallel hooks leave valid JSON" 'jq -e . "$f" >/dev/null'
out=$(printf 'not json' | HOME="$h" bash "$hook"); code=$?
ok "broken input: silent, exit 0" '[ -z "$out" ] && [ $code -eq 0 ]'
ev '{"hook_event_name":"SessionEnd","session_id":"s1"}' >/dev/null
ok "session end removes the row" '[ ! -f "$f" ]'
# A fresh heartbeat means the app runs: the hook must not start a second one, and must stay fast.
mkdir -p "$h/.claude/stack"; printf 'C:\\x\\ClaudeStack.exe' > "$h/.claude/stack/app-path"; date +%s%3N > "$h/.claude/stack/app.alive"
start=$(date +%s%N); ev '{"hook_event_name":"UserPromptSubmit","session_id":"s2","prompt":"x"}' >/dev/null; ms=$(( ($(date +%s%N) - start) / 1000000 ))
ok "no second start while the app runs, hook took $ms ms" '[ $ms -lt 1000 ]'
exit $fail
