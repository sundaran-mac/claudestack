#!/bin/bash
# Claude Stack hook. Writes this tab's status to ~/.claude/stack/sessions/<session>.json
# so the floating ClaudeStack.app can show it.
# Rules: print nothing (UserPromptSubmit output would reach Claude), always exit 0.

DIR="$HOME/.claude/stack/sessions"
APP="$HOME/Applications/ClaudeStack.app"
exec 2>/dev/null

input=$(cat)
mkdir -p "$DIR"

eval "$(jq -r '@sh "event=\(.hook_event_name // "") sid=\(.session_id // "") cwd=\(.cwd // "") tool=\(.tool_name // "") agent=\(.agent_id // "") ntype=\(.notification_type // "") nmsg=\(.message // "") source=\(.source // "") tpath=\(.transcript_path // "") detail=\(.tool_input | if type == "object" then (.command // .file_path // .pattern // .url // .query // .description // "") else "" end | tostring | gsub("\\s+"; " ") | .[0:160]) prompt=\(.prompt // "" | gsub("\\s+"; " ") | .[0:80])"' <<<"$input")" || exit 0
[ -z "$sid" ] && exit 0

file="$DIR/$sid.json"
now=$(date +%s)

# Today's log for the day coach: one short line per prompt, finished task and agent.
logday() { mkdir -p "$HOME/.claude/stack/days"; printf '{"t":%s,"e":"%s","sid":"%s"}\n' "$now" "$1" "$sid" >> "$HOME/.claude/stack/days/$(date +%F).jsonl"; }
case "$event" in
  UserPromptSubmit) logday prompt ;;
  Stop) logday stop ;;
  PreToolUse) case "$tool" in Agent|Task) logday agent ;; esac ;;
esac

if [ "$event" = "SessionEnd" ]; then
  rm -f "$file"
  exit 0
fi

start_app() {
  [ -d "$APP" ] || return
  pgrep -xq ClaudeStack || open -g "$APP"
}

# Small lock, so parallel tool hooks do not overwrite each other.
lock="$file.lock"
for _ in $(seq 1 50); do
  mkdir "$lock" 2>/dev/null && break
  # A lock older than 5 s is left over from a killed hook.
  if [ -n "$(find "$lock" -maxdepth 0 -mtime +5s 2>/dev/null)" ]; then rmdir "$lock"; fi
  sleep 0.02
done
trap 'rmdir "$lock" 2>/dev/null' EXIT

prev=$(cat "$file" 2>/dev/null)
jq -e . >/dev/null <<<"$prev" || prev='{}'
eval "$(jq -r '@sh "pstatus=\(.status // "") pagent=\(.pending_agent // "") ppid_=\(.pid // "")"' <<<"$prev")"

status=""; reason=""; pending="$pagent"
ltool=""; ptool=""
case "$event" in
  SessionStart)
    [ "$source" = "compact" ] || { status="waiting"; reason="Ready"; }
    start_app ;;
  UserPromptSubmit)
    status="running"; start_app ;;
  PreToolUse)
    case "$tool" in
      AskUserQuestion) status="needs_input"; reason="Question"; pending="$agent" ;;
      ExitPlanMode)    status="needs_input"; reason="Plan approval"; pending="$agent" ;;
      *) if [ "$pstatus" != "needs_input" ] || [ "$agent" = "$pagent" ]; then status="running"; fi
         ltool="$tool" ;;
    esac ;;
  PostToolUse|PostToolUseFailure)
    if [ "$pstatus" != "needs_input" ] || [ "$agent" = "$pagent" ]; then status="running"; fi ;;
  PermissionRequest)
    status="needs_input"; reason="Permission"; pending="$agent"; ptool="$tool" ;;
  Notification)
    case "$ntype" in
      permission_prompt) status="needs_input"; reason="Permission" ;;
      elicitation_dialog) status="needs_input"; reason="Question" ;;
      "") case "$nmsg" in *ermission*) status="needs_input"; reason="Permission" ;; esac ;;
    esac ;;
  Stop)
    status="waiting"; reason="Done" ;;
  *) ;;
esac

# Find the claude process once: walk up the parents until a process named claude.
pid="$ppid_"; tty=""
if [ -z "$pid" ]; then
  p=$PPID
  for _ in 1 2 3 4 5 6; do
    [ -z "$p" ] || [ "$p" -le 1 ] && break
    c=$(basename "$(ps -o comm= -p "$p")")
    case "$c" in claude*) pid=$p; break ;; esac
    p=$(ps -o ppid= -p "$p" | tr -d ' ')
  done
fi
[ -n "$pid" ] && tty=$(ps -o tty= -p "$pid" | tr -d ' ')

branch=""
case "$event" in SessionStart|UserPromptSubmit) branch=$(git -C "$cwd" branch --show-current 2>/dev/null) ;; esac

tmp="$file.tmp.$$"
jq -n --argjson prev "$prev" \
  --arg sid "$sid" --arg cwd "$cwd" --arg status "$status" --arg reason "$reason" \
  --arg prompt "$prompt" --arg branch "$branch" --arg pid "$pid" --arg tty "$tty" \
  --arg ltool "$ltool" --arg ptool "$ptool" --arg detail "$detail" \
  --arg tpath "$tpath" --arg term "${TERM_PROGRAM:-}" --arg pending "$pending" --argjson now "$now" '
  $prev
  + {session_id: $sid, updated_at: $now, term: (if $term != "" then $term else ($prev.term // "") end)}
  + (if $cwd != "" then {cwd: $cwd, project: ($cwd | rtrimstr("/") | split("/") | last)} else {} end)
  + (if $prev.started_at == null then {started_at: $now} else {} end)
  + (if $pid != "" then {pid: ($pid | tonumber)} else {} end)
  + (if $tty != "" and $tty != "??" then {tty: $tty} else {} end)
  + (if $branch != "" then {branch: $branch} else {} end)
  + (if $tpath != "" then {transcript_path: $tpath} else {} end)
  + (if $prompt != "" then {prompt: $prompt} else {} end)
  + (if $ltool != "" then {last_tool: $ltool, last_detail: $detail} else {} end)
  + (if $ptool != "" then {pending_tool: $ptool, pending_detail: $detail} else {} end)
  + (if $status != "" then
       {status: $status, reason: $reason, pending_agent: $pending}
       + (if $prev.status != $status or $prev.reason != $reason then {status_since: $now} else {} end)
     else {} end)
' >"$tmp" && mv -f "$tmp" "$file"
rm -f "$tmp"
exit 0
