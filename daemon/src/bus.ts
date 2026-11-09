import { EventEmitter } from "node:events";

/**
 * Server → phone messages. `sessionId` set means only clients subscribed to
 * that session receive it; otherwise it is broadcast.
 */
export interface ServerMessage {
  type: string;
  sessionId?: string;
  [k: string]: unknown;
}

class Bus extends EventEmitter {
  publish(msg: ServerMessage, scoped = false): void {
    this.emit("message", msg, scoped);
  }
}

export const bus = new Bus();
bus.setMaxListeners(100);
