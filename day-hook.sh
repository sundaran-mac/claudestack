#!/bin/bash
# Day coach time check. A UserPromptSubmit hook: whatever it prints, Claude reads with the prompt.
# It prints only on a workday, after the "check from" time (6 PM by default), and never for
# slash or ! commands. Hours come from ~/.claude/stack/day.json, which the app's Settings write.
exec 2>/dev/null
input=$(cat)
prompt=$(jq -r '.prompt // ""' <<<"$input") || exit 0
case "$prompt" in /*|!*|"") exit 0 ;; esac

conf="$HOME/.claude/stack/day.json"
get() { jq -r ".$1 // \"$2\"" "$conf" 2>/dev/null || echo "$2"; }
end=$(get end 18:30)
from=$(get checkFrom 18:00)
days=$(jq -c '.workdays // [2,3,4,5,6]' "$conf" 2>/dev/null || echo '[2,3,4,5,6]')

# date +%u is 1 for Monday; the config uses Calendar weekdays, where 1 is Sunday.
# DAYHOOK_CLOCK (HH:MM) and DAYHOOK_WEEKDAY (1-7, Sunday is 1) are for tests only.
wd=${DAYHOOK_WEEKDAY:-$(( $(date +%u) % 7 + 1 ))}
jq -e --argjson d "$wd" 'index($d) != null' <<<"$days" >/dev/null || exit 0
[ -e "$HOME/.claude/stack/days/$(date +%F).off" ] && exit 0

mins() { local h=${1%%:*} m=${1##*:}; echo $(( 10#$h * 60 + 10#$m )); }
clock=${DAYHOOK_CLOCK:-$(date +%H:%M)}
now=$(mins "$clock")
[ "$now" -lt "$(mins "$from")" ] && exit 0
left=$(( $(mins "$end") - now ))

if [ "$left" -gt 0 ]; then
  cat <<EOF
[Claude Stack day coach] It is $clock. Sundaran's workday ends at $end, so $left minutes are left.
If the prompt above is a NEW task (not a short reply such as "yes", "A" or an answer to your own question), then before doing any work:
1. Estimate how many minutes the whole task will take, including tests and the commit ask.
2. Reply first with a fenced block labelled timecheck that holds one JSON object:
   {"fits": true or false, "minutes": <your estimate>, "left": $left, "now": "<what you will do now>", "later": "<what to leave for tomorrow, or empty>"}
3. If it fits, continue with the task after the block.
4. If it does not fit, stop after the block and ask him whether to do only the part that fits now. Do not start until he answers.
If the prompt is a short reply, ignore this note and do not write the block.
EOF
else
  over=$(( -left ))
  cat <<EOF
[Claude Stack day coach] It is $clock. Sundaran's workday ended at $end, $over minutes ago.
If the prompt above is a NEW task (not a short reply), do not start it yet. Reply first with a fenced block labelled timecheck that holds one JSON object:
{"fits": false, "minutes": <your estimate>, "left": 0, "now": "<the smallest useful step, if any>", "later": "<what to leave for tomorrow>"}
Then ask him whether to stop for today or do only that small step. If the prompt is a short reply, ignore this note.
EOF
fi
exit 0
