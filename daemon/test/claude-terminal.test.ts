import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { JsonlTail, parseTerminalPrompt } from "../src/claude-history.ts";

// Captured from Claude Code 2.1.322 in a 70-column tmux pane.
const PERMISSION = `❯ run the shell command: rm hello.txt

  Removing hello.txt from the working directory
  ⎿  $ rm hello.txt

──────────────────────────────────────────────────────────────────────
 Bash command
 Tip: auto mode handles these prompts for you — choose "switch to
 auto mode" below
 Remove hello.txt from the working directory
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 rm hello.txt
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and always allow access to
      /private/tmp/permtest from this project
   3. Yes, and switch to auto mode · auto mode handles these prompts
      for you
   4. No

 Esc to cancel · Tab to amend
`;

const IDLE = `⏺ Here are the steps:
  1. Install the deps
  2. Run the tests

──────────────────────────────────────────────────────────────────────
❯ list files to confirm it's gone
──────────────────────────────────────────────────────────────────────
  ⏸ manual mode on
`;

test("parseTerminalPrompt reads Claude's permission menu", () => {
  const p = parseTerminalPrompt(PERMISSION)!;
  assert.equal(p.question, "Do you want to proceed?");
  assert.equal(p.context, "Bash command\nrm hello.txt");
  assert.deepEqual(p.options, [
    { key: "1", label: "Yes" },
    { key: "2", label: "Yes, and always allow access to /private/tmp/permtest from this project" },
    { key: "3", label: "Yes, and switch to auto mode · auto mode handles these prompts for you" },
    { key: "4", label: "No" },
  ]);
});

test("parseTerminalPrompt ignores numbered lists in replies", () => {
  assert.equal(parseTerminalPrompt(IDLE), undefined);
});

test("JsonlTail reads complete lines only and resumes from an offset", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "ah-tail-"));
  const f = path.join(dir, "s.jsonl");
  const ts = "2026-11-10T10:00:00.000Z";
  const rec = (o: object) => JSON.stringify({ timestamp: ts, ...o }) + "\n";
  fs.writeFileSync(f, rec({ type: "user", message: { content: "Fix it" } }) + '{"type":"assis');
  const t = new JsonlTail(f, dir);
  assert.deepEqual(t.read().events.map((e) => e.kind), ["user"]);
  fs.appendFileSync(f, 'tant","message":{"content":[{"type":"text","text":"Done."}]}}\n');
  fs.appendFileSync(f, rec({ type: "ai-title", aiTitle: "Fix the thing" }));
  fs.appendFileSync(f, rec({ type: "system", subtype: "turn_duration", durationMs: 1200 }));
  const r = t.read();
  assert.deepEqual(r.events.map((e) => e.kind), ["assistant", "result"]);
  assert.equal(r.aiTitle, "Fix the thing");
  assert.equal(r.customTitle, undefined);
  assert.deepEqual(t.read().events, []);
  // A daemon restart picks up where it left off.
  const t2 = new JsonlTail(f, dir, t.offset);
  fs.appendFileSync(f, rec({ type: "user", message: { content: "Thanks" } }));
  assert.deepEqual(t2.read().events.map((e) => e.kind), ["user"]);
  // /rename writes a custom-title record.
  fs.appendFileSync(f, rec({ type: "custom-title", customTitle: "agenthub" }));
  assert.equal(t2.read().customTitle, "agenthub");
  // Claude's own queue: typed while it works, delivered later.
  const q = (o: object) => fs.appendFileSync(f, rec({ type: "queue-operation", ...o }));
  q({ operation: "enqueue", content: "first" });
  q({ operation: "enqueue", content: "<task-notification>x</task-notification>" });
  q({ operation: "enqueue", content: "second" });
  assert.deepEqual(t2.read().queue, ["first", "second"]);
  q({ operation: "dequeue" });
  assert.deepEqual(t2.read().queue, ["second"]);
  q({ operation: "remove", content: "<task-notification>x</task-notification>" });
  q({ operation: "popAll", content: "second" });
  assert.deepEqual(t2.read().queue, []);
  assert.equal(t2.read().queue, undefined); // no change
});
