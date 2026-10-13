// Test modes of the Mac binary, for tests/run.sh. Usage: node cli.js --parse file.jsonl | --agents file.jsonl | --coach-sim
"use strict";
const { TranscriptReader } = require("./transcript");
const { AgentScanner } = require("./agents");

/// Same output as JSONSerialization with [.prettyPrinted, .sortedKeys].
function sortedJSON(v) {
  const sort = (x) => Array.isArray(x) ? x.map(sort)
    : (x && typeof x === "object") ? Object.fromEntries(Object.keys(x).sort().map((k) => [k, sort(x[k])])) : x;
  return JSON.stringify(sort(v), null, 2);
}

const [flag, arg] = process.argv.slice(2);
if (flag === "--parse" && arg) {
  const r = new TranscriptReader(arg);
  r.readNew();
  const out = { items: r.items.map((i) => i.json) };
  if (r.openAsk) out.ask = { tool: r.openAsk.name, input: r.openAsk.input };
  process.stdout.write(sortedJSON(out));
} else if (flag === "--agents" && arg) {
  const r = new TranscriptReader(arg);
  r.readNew();
  const list = new AgentScanner(arg).list(r.agents, r.finishedTasks, Date.now() / 1000);
  process.stdout.write(sortedJSON(list));
} else if (flag === "--coach-sim") {
  require("./coach").coachSim();
} else {
  process.stderr.write("Usage: cli.js --parse file.jsonl | --agents file.jsonl | --coach-sim\n");
  process.exit(2);
}
