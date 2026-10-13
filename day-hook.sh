#!/bin/bash
# Day coach time check. A UserPromptSubmit hook: whatever it prints, Claude reads with the prompt.
# It prints only on a workday, after the "check from" time (6 PM by default), and never for
# slash or ! commands. Hours come from ~/.claude/stack/day.json, which the app's Settings write.
# With "Find my start time automatically" (autoStart, on by default), the app writes today's hours
# to days/<date>.hours.json once you start work. No such file yet means no time check.
exec 2>/dev/null
# WSL often runs on UTC. The Windows app saves the real time zone in tz; use it for dates and hours.
[ -z "$TZ" ] && [ -s "$HOME/.claude/stack/tz" ] && export TZ="$(cat "$HOME/.claude/stack/tz")"
input=$(cat)
prompt=$(jq -r '.prompt // ""' <<<"$input") || exit 0
case "$prompt" in /*|!*|"") exit 0 ;; esac

conf="$HOME/.claude/stack/day.json"
get() { jq -r ".$1 // \"$2\"" "$conf" 2>/dev/null || echo "$2"; }
# Not "// true": jq treats false as missing there, so autoStart off would read as on.
auto=$(jq -r 'if has("autoStart") then .autoStart else true end' "$conf" 2>/dev/null || echo true)
end=$(get end 18:30)
from=$(get checkFrom 18:00)
# Whose day it is, for the note to Claude. Set "name" in day.json; without it Claude reads "The user".
who=$(get name "The user")
days=$(jq -c '.workdays // [2,3,4,5,6]' "$conf" 2>/dev/null || echo '[2,3,4,5,6]')

# date +%u is 1 for Monday; the config uses Calendar weekdays, where 1 is Sunday.
# DAYHOOK_CLOCK (HH:MM) and DAYHOOK_WEEKDAY (1-7, Sunday is 1) are for tests only.
wd=${DAYHOOK_WEEKDAY:-$(( $(date +%u) % 7 + 1 ))}
jq -e --argjson d "$wd" 'index($d) != null' <<<"$days" >/dev/null || exit 0
[ -e "$HOME/.claude/stack/days/$(date +%F).off" ] && exit 0

mins() { local h=${1%%:*} m=${1##*:}; echo $(( 10#$h * 60 + 10#$m )); }
clock=${DAYHOOK_CLOCK:-$(date +%H:%M)}
now=$(mins "$clock")
if [ "$auto" = "true" ]; then
  # Minutes from midnight, so a day that ends after midnight still compares right.
  hours="$HOME/.claude/stack/days/$(date +%F).hours.json"
  endmin=$(jq -r '.endMin // empty' "$hours" 2>/dev/null)
  frommin=$(jq -r '.checkMin // empty' "$hours" 2>/dev/null)
  end=$(jq -r '.end // empty' "$hours" 2>/dev/null)
  [ -n "$endmin" ] && [ -n "$frommin" ] && [ -n "$end" ] || exit 0
else
  endmin=$(mins "$end")
  frommin=$(mins "$from")
fi
[ "$now" -lt "$frommin" ] && exit 0
left=$(( endmin - now ))

if [ "$left" -gt 0 ]; then
  cat <<EOF
[Claude Stack day coach] It is $clock. ${who}'s workday ends at $end, so $left minutes are left.
If the prompt above is a NEW task (not a short reply such as "yes", "A" or an answer to your own question), then before doing any work:
1. Estimate how many minutes the whole task will take, including tests and the commit ask.
2. Reply first with a fenced block labelled timecheck that holds one JSON object:
   {"fits": true or false, "minutes": <your estimate>, "left": $left, "now": "<what you will do now>", "later": "<what to leave for tomorrow, or empty>"}
3. If it fits, continue with the task after the block.
4. If it does not fit, stop after the block and ask them whether to do only the part that fits now. Do not start until they answer.
If the prompt is a short reply, ignore this note and do not write the block.
EOF
else
  over=$(( -left ))
  cat <<EOF
[Claude Stack day coach] It is $clock. ${who}'s workday ended at $end, $over minutes ago.
If the prompt above is a NEW task (not a short reply), do not start it yet. Reply first with a fenced block labelled timecheck that holds one JSON object:
{"fits": false, "minutes": <your estimate>, "left": 0, "now": "<the smallest useful step, if any>", "later": "<what to leave for tomorrow>"}
Then ask them whether to stop for today or do only that small step. If the prompt is a short reply, ignore this note.
EOF
fi
exit 0
