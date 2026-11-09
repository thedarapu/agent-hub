import "./config.ts"; // augments PATH first
import { loadConfig } from "./config.ts";
import { Store } from "./db.ts";
import { SessionManager } from "./sessions.ts";
import { Server } from "./server.ts";
import { KeepAwake } from "./mac.ts";

const cfg = loadConfig();
const store = new Store();
const sm = new SessionManager(cfg, store);
const keepAwake = new KeepAwake();
const server = new Server(cfg, store, sm, keepAwake);

if (process.argv.includes("pair")) {
  // `node src/main.ts pair` prints the pairing payload (for a terminal QR tool).
  const { tailscaleIPv4 } = await import("./mac.ts");
  console.log(JSON.stringify({ host: (await tailscaleIPv4()) ?? null, port: cfg.port, token: cfg.token }));
  process.exit(0);
}

await sm.init();
await server.start();
console.log(`agent-hubd ready · base ${cfg.baseFolder}`);

function shutdown() {
  console.log("shutting down");
  keepAwake.set(false);
  sm.shutdown();
  process.exit(0);
}
process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
process.on("uncaughtException", (e) => console.error("uncaught", e));
process.on("unhandledRejection", (e) => console.error("unhandled", e));
