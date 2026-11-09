import { DatabaseSync } from "node:sqlite";
import path from "node:path";
import fs from "node:fs";
import { dataDir } from "./config.ts";
import type {
  ActivityEntry,
  Output,
  OutputVersion,
  Preset,
  Session,
  TranscriptEvent,
} from "./types.ts";

const SCHEMA = `
CREATE TABLE IF NOT EXISTS sessions (
  id TEXT PRIMARY KEY,
  data TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS transcript (
  session_id TEXT NOT NULL,
  seq INTEGER NOT NULL,
  data TEXT NOT NULL,
  PRIMARY KEY (session_id, seq)
);
CREATE TABLE IF NOT EXISTS outputs (
  id TEXT PRIMARY KEY,
  folder TEXT NOT NULL,
  session_id TEXT NOT NULL,
  kind TEXT NOT NULL,
  relpath TEXT NOT NULL,
  data TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS outputs_folder ON outputs(folder, updated_at);
CREATE TABLE IF NOT EXISTS output_versions (
  id TEXT PRIMARY KEY,
  output_id TEXT NOT NULL,
  n INTEGER NOT NULL,
  data TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS versions_output ON output_versions(output_id, n);
CREATE TABLE IF NOT EXISTS presets (
  id TEXT PRIMARY KEY,
  data TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS activity (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts TEXT NOT NULL,
  origin TEXT NOT NULL,
  action TEXT NOT NULL,
  session_id TEXT,
  detail TEXT
);
`;

export class Store {
  db: DatabaseSync;
  activityLog: string;

  constructor(file = path.join(dataDir, "state.sqlite")) {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    this.db = new DatabaseSync(file);
    this.db.exec("PRAGMA journal_mode = WAL;");
    this.db.exec(SCHEMA);
    this.activityLog = path.join(path.dirname(file), "activity.log");
  }

  // Sessions
  allSessions(): Session[] {
    return this.db
      .prepare("SELECT data FROM sessions")
      .all()
      .map((r) => JSON.parse(r.data as string));
  }
  putSession(s: Session): void {
    this.db
      .prepare("INSERT OR REPLACE INTO sessions (id, data) VALUES (?, ?)")
      .run(s.id, JSON.stringify(s));
  }
  deleteSession(id: string): void {
    this.db.prepare("DELETE FROM sessions WHERE id = ?").run(id);
    this.db.prepare("DELETE FROM transcript WHERE session_id = ?").run(id);
  }

  // Transcript
  nextSeq(sessionId: string): number {
    const r = this.db
      .prepare("SELECT MAX(seq) AS m FROM transcript WHERE session_id = ?")
      .get(sessionId);
    return ((r?.m as number | null) ?? 0) + 1;
  }
  putEvent(sessionId: string, e: TranscriptEvent): void {
    this.db
      .prepare(
        "INSERT OR REPLACE INTO transcript (session_id, seq, data) VALUES (?, ?, ?)",
      )
      .run(sessionId, e.seq, JSON.stringify(e));
  }
  transcript(sessionId: string, afterSeq = 0): TranscriptEvent[] {
    return this.db
      .prepare(
        "SELECT data FROM transcript WHERE session_id = ? AND seq > ? ORDER BY seq",
      )
      .all(sessionId, afterSeq)
      .map((r) => JSON.parse(r.data as string));
  }

  // Outputs
  putOutput(o: Output): void {
    this.db
      .prepare(
        "INSERT OR REPLACE INTO outputs (id, folder, session_id, kind, relpath, data, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
      )
      .run(o.id, o.folder, o.sessionId, o.kind, o.relpath, JSON.stringify(o), o.updatedAt);
  }
  getOutput(id: string): Output | undefined {
    const r = this.db.prepare("SELECT data FROM outputs WHERE id = ?").get(id);
    return r ? JSON.parse(r.data as string) : undefined;
  }
  findOutput(folder: string, relpath: string): Output | undefined {
    const r = this.db
      .prepare(
        "SELECT data FROM outputs WHERE folder = ? AND relpath = ? AND kind != 'changes'",
      )
      .get(folder, relpath);
    return r ? JSON.parse(r.data as string) : undefined;
  }
  outputs(folder: string, sessionId?: string): Output[] {
    const rows = sessionId
      ? this.db
          .prepare(
            "SELECT o.data FROM outputs o WHERE o.folder = ? AND (o.session_id = ? OR EXISTS (SELECT 1 FROM output_versions v WHERE v.output_id = o.id AND json_extract(v.data, '$.sessionId') = ?)) ORDER BY o.updated_at DESC",
          )
          .all(folder, sessionId, sessionId)
      : this.db
          .prepare("SELECT data FROM outputs WHERE folder = ? ORDER BY updated_at DESC")
          .all(folder);
    return rows.map((r) => JSON.parse(r.data as string));
  }
  deleteOutputsForSession(sessionId: string): void {
    this.db.prepare("DELETE FROM outputs WHERE session_id = ? AND kind = 'changes'").run(sessionId);
  }
  putVersion(v: OutputVersion): void {
    this.db
      .prepare(
        "INSERT OR REPLACE INTO output_versions (id, output_id, n, data) VALUES (?, ?, ?, ?)",
      )
      .run(v.id, v.outputId, v.n, JSON.stringify(v));
  }
  versions(outputId: string): OutputVersion[] {
    return this.db
      .prepare("SELECT data FROM output_versions WHERE output_id = ? ORDER BY n")
      .all(outputId)
      .map((r) => JSON.parse(r.data as string));
  }
  getVersion(id: string): OutputVersion | undefined {
    const r = this.db.prepare("SELECT data FROM output_versions WHERE id = ?").get(id);
    return r ? JSON.parse(r.data as string) : undefined;
  }

  // Presets
  presets(): Preset[] {
    return this.db
      .prepare("SELECT data FROM presets")
      .all()
      .map((r) => JSON.parse(r.data as string));
  }
  replacePresets(list: Preset[]): void {
    this.db.exec("DELETE FROM presets");
    const st = this.db.prepare("INSERT INTO presets (id, data) VALUES (?, ?)");
    for (const p of list) st.run(p.id, JSON.stringify(p));
  }

  // Activity (append-only)
  logActivity(origin: string, action: string, sessionId?: string, detail?: string): ActivityEntry {
    const ts = new Date().toISOString();
    const r = this.db
      .prepare(
        "INSERT INTO activity (ts, origin, action, session_id, detail) VALUES (?, ?, ?, ?, ?)",
      )
      .run(ts, origin, action, sessionId ?? null, detail ?? null);
    const line = [ts, origin, action, sessionId ?? "-", detail ?? ""].join("\t") + "\n";
    fs.appendFileSync(this.activityLog, line);
    return { id: Number(r.lastInsertRowid), ts, origin, action, sessionId, detail };
  }
  activity(limit = 200): ActivityEntry[] {
    return this.db
      .prepare("SELECT * FROM activity ORDER BY id DESC LIMIT ?")
      .all(limit)
      .map((r) => ({
        id: r.id as number,
        ts: r.ts as string,
        origin: r.origin as string,
        action: r.action as string,
        sessionId: (r.session_id as string | null) ?? undefined,
        detail: (r.detail as string | null) ?? undefined,
      }));
  }
}
