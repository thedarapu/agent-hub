import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const home = fs.mkdtempSync(path.join(os.tmpdir(), "ah-claude-home-"));
process.env.AGENT_HUB_CLAUDE_HOME = home;
const { listClaudeSessions, readHistory, sessionFile, projectKey } = await import("../src/claude-history.ts");

const folder = "/Users/x/workspace/my.app";
const A = "11111111-1111-4111-8111-111111111111";
const B = "22222222-2222-4222-8222-222222222222";
const EMPTY = "33333333-3333-4333-8333-333333333333";
const dir = path.join(home, "projects", projectKey(folder));
fs.mkdirSync(dir, { recursive: true });
fs.mkdirSync(path.join(home, "sessions"));

const line = (o: object) => JSON.stringify(o) + "\n";
const ts = "2026-11-10T10:00:00.000Z";
fs.writeFileSync(
  path.join(dir, A + ".jsonl"),
  line({ type: "user", isMeta: true, message: { role: "user", content: "<local-command-caveat>…" }, timestamp: ts }) +
    line({ type: "user", message: { role: "user", content: "<command-name>/clear</command-name>" }, timestamp: ts }) +
    line({ type: "user", message: { role: "user", content: "Fix the login bug" }, timestamp: ts }) +
    line({ type: "assistant", message: { content: [{ type: "thinking", thinking: "hmm" }, { type: "tool_use", id: "t1", name: "Read", input: { file_path: folder + "/a.ts" } }] }, timestamp: ts }) +
    line({ type: "user", message: { role: "user", content: [{ type: "tool_result", tool_use_id: "t1", content: "code" }] }, timestamp: ts }) +
    line({ type: "assistant", isSidechain: true, message: { content: [{ type: "text", text: "subagent chatter" }] }, timestamp: ts }) +
    line({ type: "assistant", message: { content: [{ type: "text", text: "Fixed." }] }, timestamp: ts }) +
    line({ type: "user", message: { role: "user", content: [{ type: "text", text: "Now add a test" }] }, timestamp: ts }) +
    "{partial",
);
fs.writeFileSync(path.join(dir, B + ".jsonl"), line({ type: "custom-title", customTitle: "named" }) + line({ type: "user", message: { role: "user", content: "hi" }, timestamp: ts }));
fs.writeFileSync(path.join(dir, EMPTY + ".jsonl"), line({ type: "summary", summary: "x" }));
fs.writeFileSync(path.join(dir, "not-a-session.jsonl"), "");
// B is open in a running CLI (this test process stands in for it).
fs.writeFileSync(path.join(home, "sessions", "1.json"), JSON.stringify({ pid: process.pid, sessionId: B }));
fs.writeFileSync(path.join(home, "sessions", "2.json"), JSON.stringify({ pid: 999999, sessionId: A }));

test("projectKey matches Claude's folder naming", () => {
  assert.equal(projectKey("/private/tmp/claude-501/x_y"), "-private-tmp-claude-501-x-y");
});

test("listClaudeSessions: prompts only, titles, live detection", () => {
  const l = listClaudeSessions(folder);
  assert.deepEqual(l.map((s) => s.id).sort(), [A, B]);
  const a = l.find((s) => s.id === A)!;
  assert.equal(a.title, "Fix the login bug");
  assert.equal(a.lastPrompt, "Now add a test");
  assert.equal(a.promptCount, 2);
  assert.equal(a.openInTerminal, false); // pid 999999 is dead
  const b = l.find((s) => s.id === B)!;
  assert.equal(b.title, "named");
  assert.equal(b.openInTerminal, true);
  assert.equal(listClaudeSessions(folder, { ownIds: new Set([B]) }).find((s) => s.id === B)!.openInTerminal, false);
});

test("sessionFile rejects non-ids", () => {
  assert.ok(sessionFile(folder, A));
  assert.equal(sessionFile(folder, "../../etc/passwd"), undefined);
  assert.equal(sessionFile(folder, "44444444-4444-4444-8444-444444444444"), undefined);
});

test("readHistory maps the main thread to transcript events", () => {
  const h = readHistory(sessionFile(folder, A)!, folder);
  assert.deepEqual(
    h.map((e) => e.kind),
    ["user", "thinking", "tool_use", "tool_result", "assistant", "user"],
  );
  assert.equal((h[2] as any).summary, "Read a.ts");
  assert.equal(h[0].ts, ts);
});
