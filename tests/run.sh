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

# Day coach: a simulated Wednesday (busy all day, three 7-minute pauses, lunch away) and a Saturday.
# Short pauses are not breaks, so rest still comes after two hours of work.
sim=$("$BIN" --coach-sim)
# After the rest, water starts again too, so the next water is an hour of work later.
# Each 7-minute pause stops work time for 2 minutes, so reminders come 2 to 4 minutes later.
expect="10:32 water
11:34 rest
12:37 water
13:00 lunch"
if [ "$(head -4 <<<"$sim")" = "$expect" ]; then echo "ok   coach: water, rest, water reset by the rest, and lunch at the right times"; else echo "FAIL coach morning:"; head -4 <<<"$sim"; fail=1; fi
for want in "auto default on=true minutes=480" "old config kept start=10:00 water=45 auto=true minutes=480" \
  "auto 08:00 phase=before" "auto 17:27 windDown" "auto 17:57 dayDone" "auto start=09:12 end=17:57 check=17:27" \
  "auto no reminders before start=true phase=done" "auto 04:30 input starts day=true" "auto restart early=07:00 now=09:30" \
  "auto end from 08:00 4h=12:00 from 14:00 8h=22:00 from 13:20 8h=21:45" "auto saturday phase=off started=false"; do
  if grep -qx "$want" <<<"$sim"; then echo "ok   coach: $want"; else echo "FAIL coach: $want missing"; fail=1; fi
done
for want in "pause 9 min keeps rest timer=true" "pause 10 min starts rest timer again=true" "18:00 windDown" "18:30 dayDone" "18:45 overtime" "19:00 overtime" "saturday phase=off reminders=false"; do
  if grep -qx "$want" <<<"$sim"; then echo "ok   coach: $want"; else echo "FAIL coach: $want missing"; fail=1; fi
done
# Work with Claude: agent time and phone prompts are work, lunch pauses it, midnight starts the day.
# Ticks are 5 s apart and the first adds nothing, so a full hour reads 59m.
for want in "agent watch work=59m breaks=0" "phone prompts work=49m breaks=0" "away idle breaks=1" \
  "claude working running=true stuck=false needs new=true needs old=false" \
  "lunch can go=true out at 13:05=true back=50 min work during lunch=0m end=17:50 card=backFromLunch(minutes: 50)" \
  "lunch after ok card=none can go=false rest=true" "lunch button back onLunch=false end=17:29" \
  "midnight agent starts day=false input start=00:30" "ghostty start today=04:00 yesterday=09:00"; do
  if grep -qx "$want" <<<"$sim"; then echo "ok   coach: $want"; else echo "FAIL coach: $want missing"; fail=1; fi
done
# Time-check hook: silent before 6 PM, on weekends and for slash commands; speaks after 6 PM.
# A temp HOME with fixed hours 09:30 to 18:30, not the ones saved in Settings.
th=$(mktemp -d)
mkdir -p "$th/.claude/stack/days"
echo '{"autoStart":false}' > "$th/.claude/stack/day.json"
hk() { printf '%s' "{\"prompt\":\"$1\"}" | HOME=$th DAYHOOK_CLOCK=$2 DAYHOOK_WEEKDAY=$3 bash ../day-hook.sh | wc -l | tr -d ' '; }
[ "$(hk "Add a page" 17:30 4)" = 0 ] && [ "$(hk "Add a page" 18:05 1)" = 0 ] && [ "$(hk "/context" 18:05 4)" = 0 ] \
  && echo "ok   day hook silent before 6 PM, on Sunday, for slash commands" || { echo "FAIL day hook spoke when it should not"; fail=1; }
printf '%s' '{"prompt":"Add a page"}' | HOME=$th DAYHOOK_CLOCK=18:05 DAYHOOK_WEEKDAY=4 bash ../day-hook.sh | grep -q "25 minutes are left" \
  && echo "ok   day hook asks for a time check at 18:05" || { echo "FAIL day hook at 18:05"; fail=1; }
printf '%s' '{"prompt":"Add a page"}' | HOME=$th DAYHOOK_CLOCK=18:50 DAYHOOK_WEEKDAY=4 bash ../day-hook.sh | grep -q "ended at 18:30, 20 minutes ago" \
  && echo "ok   day hook says the day is over at 18:50" || { echo "FAIL day hook at 18:50"; fail=1; }
# Automatic start (the default, so no day.json): silent until the app writes today's hours.
rm "$th/.claude/stack/day.json"
[ "$(hk "Add a page" 18:05 4)" = 0 ] && echo "ok   day hook (auto) silent before the day has started" || { echo "FAIL day hook (auto) spoke with no hours"; fail=1; }
echo '{"start":"09:12","end":"17:57","checkFrom":"17:27","endMin":1077,"checkMin":1047}' > "$th/.claude/stack/days/$(date +%F).hours.json"
[ "$(hk "Add a page" 17:20 4)" = 0 ] && echo "ok   day hook (auto) silent before 17:27" || { echo "FAIL day hook (auto) at 17:20"; fail=1; }
printf '%s' '{"prompt":"Add a page"}' | HOME=$th DAYHOOK_CLOCK=17:30 DAYHOOK_WEEKDAY=4 bash ../day-hook.sh | grep -q "ends at 17:57, so 27 minutes are left" \
  && echo "ok   day hook (auto) asks for a time check at 17:30" || { echo "FAIL day hook (auto) at 17:30"; fail=1; }
printf '%s' '{"prompt":"Add a page"}' | HOME=$th DAYHOOK_CLOCK=18:07 DAYHOOK_WEEKDAY=4 bash ../day-hook.sh | grep -q "ended at 17:57, 10 minutes ago" \
  && echo "ok   day hook (auto) says the day is over at 18:07" || { echo "FAIL day hook (auto) at 18:07"; fail=1; }
# autoStart false must win over the hours file (jq "//" would read false as missing).
echo '{"autoStart":false}' > "$th/.claude/stack/day.json"
[ "$(hk "Add a page" 17:30 4)" = 0 ] && echo "ok   day hook uses fixed hours when automatic start is off" || { echo "FAIL day hook read the hours file with autoStart off"; fail=1; }
rm -rf "$th"
# Live answer from a saved screen: answer text only, never a tool step or an old answer.
lv() { "$BIN" --live-parse "screens/$1.txt"; }
[ "$(lv plain | head -1)" = "The hook runs on 9 events. It writes one file per session." ] && [ "$(lv plain | tail -1)" = "- the app reads it every 0.5 s" ] \
  && echo "ok   live answer: text block, spinner and input box cut" || { echo "FAIL live answer plain"; fail=1; }
[ "$(lv tool)" = "(none)" ] && [ "$(lv old-tool)" = "(none)" ] \
  && echo "ok   live answer: tool steps are not shown" || { echo "FAIL live answer showed a tool step"; fail=1; }
[ "$(lv new-prompt)" = "(none)" ] && echo "ok   live answer: an old answer above a new prompt is not shown" || { echo "FAIL live answer new prompt"; fail=1; }
[ "$(lv empty)" = "(none)" ] && echo "ok   live answer: empty screen" || { echo "FAIL live answer empty"; fail=1; }
[ "$(lv scrolled | tail -1)" = "Shall I go with A?" ] && echo "ok   live answer: start scrolled off the top" || { echo "FAIL live answer scrolled"; fail=1; }
[ "$(lv vt-tool-on)" = "(none)" ] && [ "$(lv vt-tool-blink)" = "(none)" ] \
  && echo "ok   live answer: a grey tool mark, also when blinked off, is a tool step" || { echo "FAIL live answer read a tool step as text"; fail=1; }
[ "$(lv vt-text)" = "$(printf 'The answer has bold words.\nAnd a second line.')" ] \
  && echo "ok   live answer: white mark is text, colour codes removed" || { echo "FAIL live answer vt text"; fail=1; }
exit $fail
