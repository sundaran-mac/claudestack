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
check "roles in order" '[.items[].role] == ["user","assistant","command","output","user","assistant","note","user","assistant","command","output","user","assistant"]'
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
acheck "quiet nested agent counts as done" "$(st ddd done)"
acheck "running agents come first" '.[0].id == "ccc"'
acheck "current step of a running agent" '(.[] | select(.id == "ccc")) | .tool == "Edit" and .detail == "/repo/c.ts" and .steps == 2'
acheck "type and description from meta" '(.[] | select(.id == "aaa")) | .type == "Plan" and .desc == "Plan story A" and .depth == 1'
acheck "nested depth kept" '(.[] | select(.id == "ddd")) | .depth == 2'
main=$("$BIN" --parse agents/main.jsonl)
if [ "$(jq -r '[.items[] | select(.role == "note") | .blocks[0].text] | map(select(test("Finished: Agent"))) | length == 2' <<<"$main")" = "true" ]; then echo "ok   finished notice shown as a note"; else echo "FAIL finished notice shown as a note"; fail=1; fi
sub=$("$BIN" --parse agents/main/subagents/agent-aaa.jsonl)
if [ "$(jq -r '.items | length' <<<"$sub")" = "0" ]; then echo "ok   main reader hides agent lines"; else echo "FAIL main reader hides agent lines"; fail=1; fi

# Scrolling: a small scroll up must stay put while updates arrive; at the bottom, follow.
sc=$("$BIN" --scroll-test fixture.jsonl scroll-test.js)
if [ "$(jq -r '.movedWhileReading == 0 and .jumpButton and .gapAtEnd < 4' <<<"$sc")" = "true" ]; then echo "ok   scroll stays put while reading, follows at the bottom"; else echo "FAIL scroll: $sc"; fail=1; fi
exit $fail
