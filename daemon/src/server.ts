import http from "node:http";
import os from "node:os";
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { WebSocketServer, type WebSocket } from "ws";
import type { Config } from "./config.ts";
import { saveConfig } from "./config.ts";
import type { Store } from "./db.ts";
import { HttpError, type SessionManager } from "./sessions.ts";
import { bus, type ServerMessage } from "./bus.ts";
import { listFolders, createFolder } from "./folders.ts";
import { safeRelative, safeResolve, PathError } from "./paths.ts";
import { detectAgents, lanIPv4s, tailscaleIPv4, type AgentInfo, type KeepAwake } from "./mac.ts";
import type { Preset } from "./types.ts";
import { shellSplit } from "./shell.ts";

const MIME: Record<string, string> = {
  ".html": "text/html; charset=utf-8",
  ".htm": "text/html; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".md": "text/markdown; charset=utf-8",
  ".txt": "text/plain; charset=utf-8",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".webp": "image/webp",
  ".ico": "image/x-icon",
  ".woff": "font/woff",
  ".woff2": "font/woff2",
  ".ttf": "font/ttf",
  ".otf": "font/otf",
  ".mp4": "video/mp4",
  ".pdf": "application/pdf",
  ".diff": "text/plain; charset=utf-8",
};

function mimeFor(p: string): string {
  return MIME[path.extname(p).toLowerCase()] ?? "text/plain; charset=utf-8";
}

interface Client {
  id: string;
  ws: WebSocket;
  subs: Set<string>;
  origin: string;
}

export class Server {
  private cfg: Config;
  private store: Store;
  private sm: SessionManager;
  private keepAwake: KeepAwake;
  private servers = new Map<string, http.Server>();
  private wss = new WebSocketServer({ noServer: true, maxPayload: 4 * 1024 * 1024 });
  private clients = new Map<string, Client>();
  private agents: AgentInfo[] = [];
  private tailscaleIp?: string;
  private startedAt = new Date().toISOString();
  private tokenBuf: Buffer;

  constructor(cfg: Config, store: Store, sm: SessionManager, keepAwake: KeepAwake) {
    this.cfg = cfg;
    this.store = store;
    this.sm = sm;
    this.keepAwake = keepAwake;
    this.tokenBuf = Buffer.from(cfg.token);
    bus.on("message", (msg: ServerMessage, scoped: boolean) => this.fanout(msg, scoped));
    this.wss.on("connection", (ws: WebSocket, req: http.IncomingMessage) => this.onWs(ws, req));
  }

  async start(): Promise<void> {
    this.agents = await detectAgents();
    await this.rebind();
    setInterval(() => void this.rebind(), 15_000);
  }

  // ---------- binding ----------

  private async rebind(): Promise<void> {
    const ts = await tailscaleIPv4();
    const want = new Set(["127.0.0.1"]);
    if (ts) want.add(ts);
    if (!this.cfg.tailscaleOnly) for (const ip of lanIPv4s()) want.add(ip);
    let changed = ts !== this.tailscaleIp;
    this.tailscaleIp = ts;
    for (const [addr, srv] of this.servers) {
      if (!want.has(addr)) {
        srv.close();
        this.servers.delete(addr);
        changed = true;
        console.log(`stopped listening on ${addr}`);
      }
    }
    for (const addr of want) {
      if (this.servers.has(addr)) continue;
      const srv = http.createServer((req, res) => void this.handle(req, res));
      srv.on("upgrade", (req, sock, head) => this.onUpgrade(req, sock, head));
      await new Promise<void>((resolve) => {
        srv.once("error", (e) => {
          console.error(`listen ${addr}:${this.cfg.port} failed:`, (e as Error).message);
          resolve();
        });
        srv.listen(this.cfg.port, addr, () => {
          this.servers.set(addr, srv);
          console.log(`listening on http://${addr}:${this.cfg.port}`);
          changed = true;
          resolve();
        });
      });
    }
    if (changed) bus.publish({ type: "mac.updated", mac: this.macStatus() });
  }

  macStatus() {
    return {
      hostname: os.hostname().replace(/\.local$/, ""),
      awake: this.keepAwake.on,
      keepAwake: this.keepAwake.on,
      tailscaleIp: this.tailscaleIp ?? null,
      tailscaleOnly: this.cfg.tailscaleOnly,
      listening: [...this.servers.keys()],
      port: this.cfg.port,
      baseFolder: this.cfg.baseFolder,
      sshHosts: this.cfg.sshHosts,
      agents: this.agents,
      startedAt: this.startedAt,
      clients: this.clients.size,
      version: "0.1.0",
    };
  }

  pairing() {
    return { host: this.tailscaleIp ?? null, port: this.cfg.port, token: this.cfg.token, name: this.macStatus().hostname };
  }

  // ---------- auth ----------

  private authorized(req: http.IncomingMessage): boolean {
    const h = req.headers.authorization ?? "";
    const m = h.match(/^Bearer\s+(.+)$/i);
    if (!m) return false;
    const got = Buffer.from(m[1].trim());
    return got.length === this.tokenBuf.length && crypto.timingSafeEqual(got, this.tokenBuf);
  }

  private originOf(req: http.IncomingMessage): string {
    const a = req.socket.remoteAddress ?? "";
    return a === "127.0.0.1" || a === "::1" || a === "::ffff:127.0.0.1" ? "mac" : "phone";
  }

  // ---------- HTTP ----------

  private async handle(req: http.IncomingMessage, res: http.ServerResponse): Promise<void> {
    const url = new URL(req.url ?? "/", "http://x");
    const p = url.pathname;
    try {
      if (p === "/health") return json(res, 200, { ok: true });
      if (!this.authorized(req)) return json(res, 401, { error: "unauthorized" });
      const origin = this.originOf(req);
      const method = req.method ?? "GET";
      const seg = p.split("/").filter(Boolean);

      if (seg[0] === "files" && seg.length >= 3 && method === "GET") return this.serveFile(res, seg[1], seg.slice(2).join("/"));
      if (seg[0] === "vfiles" && seg.length >= 4 && method === "GET") return this.serveVersioned(res, seg[1], seg[2], seg.slice(3).join("/"));

      const body = method === "GET" || method === "DELETE" ? {} : await readJson(req);

      switch (`${method} /${seg[0] ?? ""}`) {
        case "GET /mac":
          return json(res, 200, this.macStatus());
        case "PATCH /mac": {
          if (typeof body.keepAwake === "boolean") {
            this.keepAwake.set(body.keepAwake);
            this.store.logActivity(origin, "mac.keepAwake", undefined, String(body.keepAwake));
          }
          if (typeof body.tailscaleOnly === "boolean") {
            this.cfg.tailscaleOnly = body.tailscaleOnly;
            saveConfig(this.cfg);
            this.store.logActivity(origin, "mac.tailscaleOnly", undefined, String(body.tailscaleOnly));
            await this.rebind();
          }
          if (Array.isArray(body.sshHosts)) {
            this.cfg.sshHosts = body.sshHosts.map(String);
            saveConfig(this.cfg);
          }
          const st = this.macStatus();
          bus.publish({ type: "mac.updated", mac: st });
          return json(res, 200, st);
        }
        case "GET /pairing":
          if (origin !== "mac") return json(res, 403, { error: "pairing info is only available on the Mac" });
          return json(res, 200, this.pairing());
        case "GET /activity":
          return json(res, 200, this.store.activity(Number(url.searchParams.get("limit") ?? 200)));
        case "GET /folders":
          return json(res, 200, { base: this.cfg.baseFolder, ...listFolders(this.cfg.baseFolder, url.searchParams.get("path") ?? "", this.sm.sessionCountByFolder()) });
        case "GET /claude-sessions":
          // Claude sessions started outside agent-hub, for a project folder.
          return json(res, 200, this.sm.claudeHistory(url.searchParams.get("project") ?? ""));
        case "POST /claude-sessions": {
          const s = this.sm.resumeClaude(body, origin);
          return json(res, 201, s);
        }
        case "POST /folders": {
          const abs = createFolder(this.cfg.baseFolder, String(body.path ?? ""));
          this.store.logActivity(origin, "folder.create", undefined, abs);
          return json(res, 201, { path: path.relative(this.cfg.baseFolder, abs), absolute: abs });
        }
        case "GET /presets":
          return json(res, 200, this.store.presets());
        case "PUT /presets": {
          if (!Array.isArray(body)) throw new HttpError(400, "expected array");
          const list: Preset[] = body.map((x: any) => ({
            id: String(x.id ?? crypto.randomUUID()),
            folder: safeResolve(this.cfg.baseFolder, String(x.folder)),
            agent: x.agent,
            flags: Array.isArray(x.flags) ? x.flags.map(String) : shellSplit(String(x.flags ?? "")),
            label: String(x.label ?? ""),
          }));
          this.store.replacePresets(list);
          return json(res, 200, list);
        }
        case "POST /hooks": {
          // Local integrations (Amp plugin) report agent lifecycle events.
          if (origin !== "mac") return json(res, 403, { error: "local only" });
          this.sm.hookEvent(String(body.sessionId ?? ""), String(body.event ?? ""));
          return json(res, 200, { ok: true });
        }
      }

      if (seg[0] === "sessions") return await this.sessionsRoute(req, res, seg, method, body, origin, url);
      if (seg[0] === "outputs") return await this.outputsRoute(res, seg, method, url);
      return json(res, 404, { error: "not found" });
    } catch (e: any) {
      const status = e instanceof HttpError || e instanceof PathError ? e.status : e.status ?? (e.code === "ENOENT" ? 404 : 500);
      if (status >= 500) console.error(e);
      return json(res, status, { error: e.message ?? String(e) });
    }
  }

  private async sessionsRoute(_req: http.IncomingMessage, res: http.ServerResponse, seg: string[], method: string, body: any, origin: string, url: URL) {
    const id = seg[1];
    const action = seg[2];
    if (!id) {
      if (method === "GET") return json(res, 200, this.sm.list());
      if (method === "POST") {
        const s = await this.sm.create(body, origin);
        return json(res, 201, s);
      }
    } else if (!action) {
      if (method === "GET") return json(res, 200, { ...this.sm.get(id), pendingApprovals: this.sm.pendingApprovals(id).map(publicApproval) });
      if (method === "PATCH") return json(res, 200, this.sm.patch(id, body, origin));
      if (method === "DELETE") {
        await this.sm.delete(id, origin);
        return json(res, 200, { ok: true });
      }
    } else if (method === "POST" && action === "stop") {
      return json(res, 200, await this.sm.stop(id, origin));
    } else if (method === "POST" && action === "prompt") {
      this.sm.prompt(id, String(body.text ?? ""), origin);
      return json(res, 202, { ok: true });
    } else if (method === "POST" && action === "interrupt") {
      this.sm.interrupt(id, origin);
      return json(res, 202, { ok: true });
    } else if (method === "POST" && action === "screenshot") {
      const o = await this.sm.screenshot(id, body.target === "mac" ? "mac" : "simulator", origin);
      return json(res, 201, o ?? { unchanged: true });
    } else if (method === "GET" && action === "transcript") {
      return json(res, 200, this.sm.transcript(id, Number(url.searchParams.get("after") ?? 0)));
    }
    return json(res, 404, { error: "not found" });
  }

  private async outputsRoute(res: http.ServerResponse, seg: string[], method: string, url: URL) {
    if (method !== "GET") return json(res, 405, { error: "method not allowed" });
    const id = seg[1];
    if (!id) {
      const project = url.searchParams.get("project");
      if (!project) throw new HttpError(400, "project required");
      const folder = safeResolve(this.cfg.baseFolder, project);
      return json(res, 200, this.store.outputs(folder, url.searchParams.get("session") ?? undefined));
    }
    const o = this.store.getOutput(id);
    if (!o) throw new HttpError(404, "no such output");
    if (!seg[2]) return json(res, 200, o);
    if (seg[2] === "versions") return json(res, 200, this.store.versions(id));
    if (seg[2] === "diff") {
      const abs = safeRelative(o.folder, o.relpath);
      res.writeHead(200, { "content-type": "text/plain; charset=utf-8" });
      return void res.end(fs.readFileSync(abs));
    }
    return json(res, 404, { error: "not found" });
  }

  private serveFile(res: http.ServerResponse, sessionId: string, rel: string): void {
    const s = this.sm.get(sessionId);
    const abs = safeRelative(s.folder, rel);
    sendFile(res, abs);
  }

  /** Serve a stored version at the original path so relative assets still resolve. */
  private serveVersioned(res: http.ServerResponse, sessionId: string, versionId: string, rel: string): void {
    const s = this.sm.get(sessionId);
    const v = this.store.getVersion(versionId);
    if (!v) throw new HttpError(404, "no such version");
    const o = this.store.getOutput(v.outputId);
    const decoded = rel.split("/").map(decodeURIComponent).join("/");
    if (o && o.folder === s.folder && path.normalize(decoded) === path.normalize(o.relpath)) {
      return sendFile(res, safeRelative(s.folder, v.storedPath), o.relpath);
    }
    sendFile(res, safeRelative(s.folder, rel));
  }

  // ---------- WebSocket ----------

  private onUpgrade(req: http.IncomingMessage, sock: import("node:stream").Duplex, head: Buffer): void {
    const url = new URL(req.url ?? "/", "http://x");
    if (url.pathname !== "/ws" || !this.authorized(req)) {
      sock.write("HTTP/1.1 401 Unauthorized\r\n\r\n");
      sock.destroy();
      return;
    }
    this.wss.handleUpgrade(req, sock, head, (ws) => this.wss.emit("connection", ws, req));
  }

  private onWs(ws: WebSocket, req: http.IncomingMessage): void {
    const c: Client = { id: crypto.randomUUID(), ws, subs: new Set(), origin: this.originOf(req) };
    this.clients.set(c.id, c);
    send(ws, { type: "hello", sessions: this.sm.list(), mac: this.macStatus(), approvals: this.sm.pendingApprovals().map(publicApproval) });
    bus.publish({ type: "mac.updated", mac: this.macStatus() });
    let alive = true;
    const ping = setInterval(() => {
      if (!alive) return ws.terminate();
      alive = false;
      ws.ping();
    }, 20_000);
    ws.on("pong", () => (alive = true));
    ws.on("message", (raw) => {
      let m: any;
      try {
        m = JSON.parse(raw.toString());
      } catch {
        return send(ws, { type: "error", message: "bad json" });
      }
      try {
        this.onWsMessage(c, m);
      } catch (e: any) {
        send(ws, { type: "error", ref: m.ref, message: e.message ?? String(e) });
      }
    });
    ws.on("close", () => {
      clearInterval(ping);
      this.clients.delete(c.id);
      this.sm.unsubscribeAll(c.id);
      bus.publish({ type: "mac.updated", mac: this.macStatus() });
    });
  }

  private onWsMessage(c: Client, m: any): void {
    const sid = String(m.sessionId ?? "");
    switch (m.type) {
      case "ping":
        return send(c.ws, { type: "pong", ref: m.ref });
      case "subscribe": {
        const s = this.sm.get(sid);
        c.subs.add(sid);
        if (s.mode === "terminal") this.sm.subscribeTerminal(sid, c.id, m.cols, m.rows);
        return send(c.ws, { type: "subscribed", ref: m.ref, sessionId: sid });
      }
      case "unsubscribe":
        c.subs.delete(sid);
        return this.sm.unsubscribeTerminal(sid, c.id);
      case "prompt.send":
        this.sm.prompt(sid, String(m.text ?? ""), c.origin);
        return send(c.ws, { type: "ack", ref: m.ref });
      case "terminal.input":
        return this.sm.terminalInput(sid, Buffer.from(String(m.data ?? ""), "base64"));
      case "terminal.resize":
        return this.sm.terminalResize(sid, Number(m.cols), Number(m.rows));
      case "approval.respond":
        this.sm.respondApproval(String(m.requestId), m.decision, c.origin);
        return send(c.ws, { type: "ack", ref: m.ref });
      case "session.interrupt":
        this.sm.interrupt(sid, c.origin);
        return send(c.ws, { type: "ack", ref: m.ref });
      default:
        return send(c.ws, { type: "error", ref: m.ref, message: `unknown type ${m.type}` });
    }
  }

  private fanout(msg: ServerMessage, scoped: boolean): void {
    const data = JSON.stringify(msg);
    for (const c of this.clients.values()) {
      if (scoped && (!msg.sessionId || !c.subs.has(msg.sessionId))) continue;
      // Drop terminal frames for a client that can't keep up; tmux repaints on resubscribe.
      if (msg.type === "terminal.data" && c.ws.bufferedAmount > 4 * 1024 * 1024) continue;
      if (c.ws.readyState === c.ws.OPEN) c.ws.send(data);
    }
  }
}

function publicApproval(a: { requestId: string; sessionId: string; tool: string; summary: string; input: unknown; createdAt: string }) {
  return { requestId: a.requestId, sessionId: a.sessionId, tool: a.tool, summary: a.summary, input: a.input, createdAt: a.createdAt };
}

function send(ws: WebSocket, obj: unknown): void {
  if (ws.readyState === ws.OPEN) ws.send(JSON.stringify(obj));
}

function json(res: http.ServerResponse, status: number, body: unknown): void {
  const data = JSON.stringify(body);
  res.writeHead(status, { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" });
  res.end(data);
}

function sendFile(res: http.ServerResponse, abs: string, nameForType = abs): void {
  const st = fs.statSync(abs);
  if (!st.isFile()) throw new HttpError(404, "not a file");
  res.writeHead(200, {
    "content-type": mimeFor(nameForType),
    "content-length": st.size,
    "cache-control": "no-store",
    "x-content-type-options": "nosniff",
  });
  fs.createReadStream(abs).pipe(res);
}

async function readJson(req: http.IncomingMessage): Promise<any> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const ch of req) {
    size += (ch as Buffer).length;
    if (size > 2 * 1024 * 1024) throw new HttpError(413, "body too large");
    chunks.push(ch as Buffer);
  }
  if (!chunks.length) return {};
  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch {
    throw new HttpError(400, "bad json");
  }
}
