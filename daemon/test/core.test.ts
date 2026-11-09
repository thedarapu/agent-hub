import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { shellSplit, shellJoin } from "../src/shell.ts";
import { safeResolve } from "../src/paths.ts";
import { classify, htmlTitle } from "../src/outputs.ts";
import { summarizeTool, approvalSummary } from "../src/adapters/claude.ts";

test("shellSplit handles quotes and escapes, no expansion", () => {
  assert.deepEqual(shellSplit(`--model opus --foo 'two words' -x="q" a\\ b $HOME`), ["--model", "opus", "--foo", "two words", "-x=q", "a b", "$HOME"]);
  assert.deepEqual(shellSplit(""), []);
  assert.deepEqual(shellSplit(`''`), [""]);
  assert.throws(() => shellSplit(`'open`));
});

test("shellJoin round-trips through shellSplit", () => {
  const argv = ["--a", "two words", "it's", "", "$X", "plain"];
  assert.deepEqual(shellSplit(shellJoin(argv)), argv);
});

test("safeResolve rejects escapes and outside symlinks", () => {
  const base = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "ah-")));
  fs.mkdirSync(path.join(base, "proj"));
  fs.symlinkSync("/etc", path.join(base, "proj", "evil"));
  assert.equal(safeResolve(base, "proj"), path.join(base, "proj"));
  assert.equal(safeResolve(base, "proj/new/file.txt"), path.join(base, "proj/new/file.txt"));
  assert.throws(() => safeResolve(base, "../etc"));
  assert.throws(() => safeResolve(base, "/etc/passwd"));
  assert.throws(() => safeResolve(base, "proj/evil/passwd"));
});

test("classify outputs", () => {
  assert.equal(classify("mock/home.html"), "page");
  assert.equal(classify("a.PNG"), "image");
  assert.equal(classify("NOTES.md"), "markdown");
  assert.equal(classify("Sources/App.swift"), "code");
  assert.equal(classify("node_modules/x/index.js"), null);
  assert.equal(classify(".agent-hub/versions/a.html"), null);
  assert.equal(classify("build.zip"), null);
});

test("htmlTitle", () => {
  assert.equal(htmlTitle(Buffer.from("<html><head><title> Home redesign </title>")), "Home redesign");
  assert.equal(htmlTitle(Buffer.from("<p>x</p>")), undefined);
});

test("tool summaries", () => {
  assert.equal(summarizeTool("Read", { file_path: "/w/p/a.swift" }, "/w/p"), "Read a.swift");
  assert.equal(approvalSummary("Bash", { command: "xcodebuild -scheme Binge test" }, "Run tests", "/w"), "Run xcodebuild -scheme Binge test");
  assert.equal(approvalSummary("Write", { file_path: "/w/hello.html" }, "x", "/w"), "Write hello.html");
});
