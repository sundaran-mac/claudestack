#!/bin/bash
# Parser tests for the reader. Usage: tests/run.sh [path to ClaudeStack binary]
set -uo pipefail
cd "$(dirname "$0")"
BIN="${1:-$HOME/Applications/ClaudeStack.app/Contents/MacOS/ClaudeStack}"
out=$("$BIN" --parse fixture.jsonl)
fail=0
check() { # name, jq expression that must print true
  if [ "$(jq -r "$2" <<<"$out")" = "true" ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi
}
check "roles in order" '[.items[].role] == ["user","assistant","command","output","user","assistant","note","user","assistant","command","output","user","assistant","user","assistant"]'
check "thinking is hidden" '[.items[].blocks[].text // empty] | map(test("secret")) | any | not'
check "subagent lines are hidden" '[.items[].blocks[].text // empty] | map(test("SUBAGENT")) | any | not'
check "meta caveat is hidden" '[.items[].blocks[].text // empty] | map(test("Caveat")) | any | not'
check "tool result attached" '.items[1].blocks[1].output == "120 passed"'
check "ansi colours removed" '.items[3].blocks[0].text == "Context usage 12%"'
check "array tool result joined" '.items[1].blocks[2].output == "1\tconst a = 1"'
check "text after tools stays in the same bubble" '.items[1].blocks[3].text == "Done. Both suites are green."'
check "slash command shown" '.items[2].blocks[0].text == "/context"'
check "Esc becomes a note" '.items[6].role == "note"'
check "tool detail is the command" '.items[1].blocks[1].detail == "npm run test -w apps/api"'
check "open question found" '.ask.tool == "AskUserQuestion" and (.ask.input.questions[0].options | length) == 2'
check "new-style slash command" '.items[9].blocks[0].text == "/model opus" and .items[10].blocks[0].text == "Set model to Opus"'
check "running tool has no output yet" '.items[5].blocks[0] | has("output") | not'

# Agents: three from the main chat plus one nested agent.
touch -t 202601010000 agents/main/subagents/agent-ddd.jsonl   # nested, quiet for long: done
touch agents/main/subagents/agent-ccc.jsonl                     # background, still writing: running
ag=$("$BIN" --agents agents/main.jsonl)
acheck() { if [ "$(jq -r "$2" <<<"$ag")" = "true" ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
st() { echo "(.[] | select(.id == \"$1\") | .status) == \"$2\""; }
acheck "foreground agent done after its result" "$(st aaa done)"
acheck "background agent done after its notice" "$(st bbb done)"
acheck "background agent without notice is running" "$(st ccc running)"
touch agents/main/subagents/agent-eee.jsonl
acheck "agent done by a queued notice" "$(st eee done)"
touch agents/main/subagents/agent-fff.jsonl agents/main/subagents/agent-ggg.jsonl
acheck "agent done by a notice that names only its task id" "$(st fff done)"
acheck "agent done by its hand-back message" "$(st ggg done)"
acheck "quiet nested agent counts as done" "$(st ddd done)"
acheck "running agents come first" '.[0].id == "ccc"'
acheck "current step of a running agent" '(.[] | select(.id == "ccc")) | .tool == "Edit" and .detail == "/repo/c.ts" and .steps == 3'
acheck "type and description from meta" '(.[] | select(.id == "aaa")) | .type == "Plan" and .desc == "Plan story A" and .depth == 1'
acheck "nested depth kept" '(.[] | select(.id == "ddd")) | .depth == 2'
acheck "nested agent knows who started it" '(.[] | select(.id == "ddd")) | .parent == "ccc"'
acheck "agents started by the lead have no parent" '(.[] | select(.id == "aaa")) | .parent == ""'
main=$("$BIN" --parse agents/main.jsonl)
if [ "$(jq -r '[.items[] | select(.role == "note") | .blocks[0].text] | map(select(test("Finished: Agent"))) | length == 2' <<<"$main")" = "true" ]; then echo "ok   finished notice shown as a note"; else echo "FAIL finished notice shown as a note"; fail=1; fi
if [ "$(jq -r '[.items[] | select(.role == "note") | .blocks[0].text] | any(test("handed back"))' <<<"$main")" = "true" ]; then echo "ok   hand-back shown as a short note"; else echo "FAIL hand-back note"; fail=1; fi
if [ "$(jq -r '[.items[] | select(.role == "user") | .blocks[0].text] | any(test("Please fix the ring animation"))' <<<"$main")" = "true" ]; then echo "ok   your words stay when a hand-back is attached"; else echo "FAIL your words were hidden"; fail=1; fi
sub=$("$BIN" --parse agents/main/subagents/agent-aaa.jsonl)
if [ "$(jq -r '.items | length' <<<"$sub")" = "0" ]; then echo "ok   main reader hides agent lines"; else echo "FAIL main reader hides agent lines"; fail=1; fi

# Scrolling: a small scroll up must stay put while updates arrive; at the bottom, follow.
sc=$("$BIN" --scroll-test fixture.jsonl scroll-test.js)
if [ "$(jq -r '.movedWhileReading == 0 and .jumpButton and .gapAtEnd < 4' <<<"$sc")" = "true" ]; then echo "ok   scroll stays put while reading, follows at the bottom"; else echo "FAIL scroll: $sc"; fail=1; fi

# Day coach: a simulated Wednesday (busy all day, a short pause at 11:40, lunch away) and a Saturday.
sim=$("$BIN" --coach-sim)
expect="10:30 water
11:30 rest
11:46 water
12:47 water
13:00 lunch"
if [ "$(head -5 <<<"$sim")" = "$expect" ]; then echo "ok   coach: water, rest, cooldown and lunch at the right times"; else echo "FAIL coach morning:"; head -5 <<<"$sim"; fail=1; fi
for want in "18:00 windDown" "18:30 dayDone" "18:45 overtime" "19:00 overtime" "saturday phase=off reminders=false"; do
  if grep -qx "$want" <<<"$sim"; then echo "ok   coach: $want"; else echo "FAIL coach: $want missing"; fail=1; fi
done
# Time-check hook: silent before 6 PM, on weekends and for slash commands; speaks after 6 PM.
# An empty HOME, so the hook uses the default hours and not the ones saved in Settings.
th=$(mktemp -d)
hk() { printf '%s' "{\"prompt\":\"$1\"}" | HOME=$th DAYHOOK_CLOCK=$2 DAYHOOK_WEEKDAY=$3 bash ../day-hook.sh | wc -l | tr -d ' '; }
[ "$(hk "Add a page" 17:30 4)" = 0 ] && [ "$(hk "Add a page" 18:05 1)" = 0 ] && [ "$(hk "/context" 18:05 4)" = 0 ] \
  && echo "ok   day hook silent before 6 PM, on Sunday, for slash commands" || { echo "FAIL day hook spoke when it should not"; fail=1; }
printf '%s' '{"prompt":"Add a page"}' | HOME=$th DAYHOOK_CLOCK=18:05 DAYHOOK_WEEKDAY=4 bash ../day-hook.sh | grep -q "25 minutes are left" \
  && echo "ok   day hook asks for a time check at 18:05" || { echo "FAIL day hook at 18:05"; fail=1; }
printf '%s' '{"prompt":"Add a page"}' | HOME=$th DAYHOOK_CLOCK=18:50 DAYHOOK_WEEKDAY=4 bash ../day-hook.sh | grep -q "ended at 18:30, 20 minutes ago" \
  && echo "ok   day hook says the day is over at 18:50" || { echo "FAIL day hook at 18:50"; fail=1; }
rm -rf "$th"
exit $fail
