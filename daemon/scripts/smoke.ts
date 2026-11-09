// End-to-end smoke test against a running daemon.
//   node scripts/smoke.ts <baseUrl> <token> <folderRel> [terminal|claude|outputs]
import WebSocket from "ws";

const [base, token, folder, which = "terminal"] = process.argv.slice(2);
const H = { authorization: `Bearer ${token}`, "content-type": "application/json" };

async function api(method: string, p: string, body?: unknown) {
  const r = await fetch(base + p, { method, headers: H, body: body ? JSON.stringify(body) : undefined });
  const t = await r.text();
  if (!r.ok) throw new Error(`${method} ${p} → ${r.status} ${t}`);
  return t ? JSON.parse(t) : null;
}

function ws(): Promise<WebSocket> {
  return new Promise((res, rej) => {
    const w = new WebSocket(base.replace("http", "ws") + "/ws", { headers: { authorization: `Bearer ${token}` } });
    w.once("open", () => res(w));
    w.once("error", rej);
  });
}

const wait = (ms: number) => new Promise((r) => setTimeout(r, ms));
function assert(c: unknown, msg: string) {
  if (!c) {
    console.error("FAIL:", msg);
    process.exit(1);
  }
  console.log("ok:", msg);
}

if (which === "terminal") {
  const s = await api("POST", "/sessions", { folder, agent: "shell", flags: "" });
  assert(s.id && s.mode === "terminal", `created ${s.id}`);
  const w = await ws();
  let screen = "";
  w.on("message", (raw) => {
    const m = JSON.parse(raw.toString());
    if (m.type === "terminal.data" && m.sessionId === s.id) screen += Buffer.from(m.data, "base64").toString();
  });
  w.send(JSON.stringify({ type: "subscribe", sessionId: s.id, cols: 100, rows: 30 }));
  await wait(1500);
  w.send(JSON.stringify({ type: "terminal.input", sessionId: s.id, data: Buffer.from("ls -1\r").toString("base64") }));
  await wait(1500);
  assert(screen.includes("README.md"), "ls output streamed back");
  w.send(JSON.stringify({ type: "prompt.send", sessionId: s.id, text: "echo from-composer-$((40+2))" }));
  await wait(1500);
  assert(screen.includes("from-composer-42"), "composer text + Enter reached the shell");
  w.close();
  await wait(500);
  // Reconnect: session persists and repaints.
  const w2 = await ws();
  let screen2 = "";
  w2.on("message", (raw) => {
    const m = JSON.parse(raw.toString());
    if (m.type === "terminal.data") screen2 += Buffer.from(m.data, "base64").toString();
  });
  w2.send(JSON.stringify({ type: "subscribe", sessionId: s.id, cols: 100, rows: 30 }));
  await wait(1500);
  assert(screen2.includes("from-composer-42"), "reconnect repaints existing screen");
  w2.close();
  const list = await api("GET", "/sessions");
  assert(list.some((x: any) => x.id === s.id), "session listed");
  const renamed = await api("PATCH", `/sessions/${s.id}`, { name: "Renamed", pinned: true });
  assert(renamed.name === "Renamed" && renamed.pinned, "rename + pin");
  console.log("SESSION", s.id);
  process.exit(0);
}

if (which === "claude") {
  const s = await api("POST", "/sessions", { folder, agent: "claude", flags: "--model sonnet" });
  const w = await ws();
  const events: any[] = [];
  let deltas = "";
  let approval: any = null;
  w.on("message", (raw) => {
    const m = JSON.parse(raw.toString());
    if (m.sessionId !== s.id) return;
    if (m.type === "transcript.event") events.push(m.event);
    if (m.type === "transcript.delta") deltas += m.text;
    if (m.type === "approval.request") approval = m;
  });
  w.send(JSON.stringify({ type: "subscribe", sessionId: s.id }));
  await wait(300);
  w.send(JSON.stringify({ type: "prompt.send", sessionId: s.id, text: "Create a file hello.html containing a tiny HTML page titled Hello Hub. Use the Write tool. Then reply 'written'." }));
  for (let i = 0; i < 120 && !approval; i++) await wait(500);
  assert(approval, `approval requested: ${approval?.summary}`);
  const st = (await api("GET", `/sessions/${s.id}`)).status;
  assert(st === "waiting", `status waiting (${st})`);
  w.send(JSON.stringify({ type: "approval.respond", requestId: approval.requestId, decision: "allow" }));
  for (let i = 0; i < 180 && !events.some((e) => e.kind === "result"); i++) await wait(500);
  assert(events.some((e) => e.kind === "result" && !e.isError), "turn completed");
  assert(deltas.length > 0, "streamed text deltas");
  await wait(1500);
  const outs = await api("GET", `/outputs?project=${encodeURIComponent(folder)}&session=${s.id}`);
  assert(outs.some((o: any) => o.relpath === "hello.html"), "hello.html recorded as output");
  const tr = await api("GET", `/sessions/${s.id}/transcript`);
  assert(tr.some((e: any) => e.kind === "output"), "output card in transcript");
  console.log("SESSION", s.id, "agentSessionId", (await api("GET", `/sessions/${s.id}`)).agentSessionId);
  process.exit(0);
}
