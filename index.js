import { WebSocketServer } from "ws";
import { createServer } from "http";

const PORT = Number(process.env.PORT || 3847);

/** @typedef {{ code: string, fullness: number, happiness: number, updatedAt: number, members: Map<any, string> }} Room */

/** @type {Map<string, Room>} */
const rooms = new Map();

function code() {
  const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  let out = "";
  for (let i = 0; i < 6; i++) out += alphabet[Math.floor(Math.random() * alphabet.length)];
  return out;
}

function uniqueCode() {
  let c;
  do c = code();
  while (rooms.has(c));
  return c;
}

function roomPayload(room, self) {
  const others = [...room.members.entries()]
    .filter(([ws]) => ws !== self)
    .map(([, name]) => name);
  return {
    type: "room",
    code: room.code,
    fullness: room.fullness,
    happiness: room.happiness,
    updatedAt: room.updatedAt,
    you: room.members.get(self) || "",
    partner: others[0] || null,
    members: [...room.members.values()],
  };
}

function send(ws, msg) {
  if (ws.readyState === 1) ws.send(JSON.stringify(msg));
}

function broadcast(room, msg, except = null) {
  for (const ws of room.members.keys()) {
    if (ws !== except) send(ws, msg);
  }
}

function leave(ws) {
  const room = ws.room;
  if (!room) return;
  room.members.delete(ws);
  ws.room = null;
  if (room.members.size === 0) {
    rooms.delete(room.code);
    return;
  }
  for (const peer of room.members.keys()) send(peer, roomPayload(room, peer));
  broadcast(room, { type: "system", text: "partner left" });
}

const httpServer = createServer((_req, res) => {
  res.writeHead(200, { "content-type": "text/plain" });
  res.end("mochi online ✓\n");
});

const wss = new WebSocketServer({ server: httpServer });

wss.on("connection", (ws) => {
  ws.room = null;

  ws.on("message", (raw) => {
    let msg;
    try {
      msg = JSON.parse(String(raw));
    } catch {
      return send(ws, { type: "error", text: "bad json" });
    }

    if (msg.type === "create") {
      leave(ws);
      const name = String(msg.name || "friend").slice(0, 24);
      const room = {
        code: uniqueCode(),
        fullness: Number.isFinite(msg.fullness) ? msg.fullness : 80,
        happiness: Number.isFinite(msg.happiness) ? msg.happiness : 80,
        updatedAt: Date.now(),
        members: new Map([[ws, name]]),
      };
      rooms.set(room.code, room);
      ws.room = room;
      return send(ws, roomPayload(room, ws));
    }

    if (msg.type === "join") {
      const room = rooms.get(String(msg.code || "").toUpperCase());
      if (!room) return send(ws, { type: "error", text: "room not found" });
      if (room.members.size >= 2) return send(ws, { type: "error", text: "room full (v1 is 2 people)" });
      leave(ws);
      const name = String(msg.name || "friend").slice(0, 24);
      room.members.set(ws, name);
      ws.room = room;
      for (const peer of room.members.keys()) send(peer, roomPayload(room, peer));
      return broadcast(room, { type: "system", text: `${name} joined` }, ws);
    }

    if (msg.type === "sync") {
      const room = ws.room;
      if (!room) return;
      const at = Number(msg.updatedAt) || Date.now();
      if (at < room.updatedAt) {
        return send(ws, roomPayload(room, ws));
      }
      if (Number.isFinite(msg.fullness)) room.fullness = Math.max(0, Math.min(100, msg.fullness));
      if (Number.isFinite(msg.happiness)) room.happiness = Math.max(0, Math.min(100, msg.happiness));
      room.updatedAt = at;
      const payload = {
        type: "sync",
        fullness: room.fullness,
        happiness: room.happiness,
        updatedAt: room.updatedAt,
        action: msg.action || null,
        from: room.members.get(ws) || "",
      };
      return broadcast(room, payload, null);
    }

    if (msg.type === "ping") return send(ws, { type: "pong" });
  });

  ws.on("close", () => leave(ws));
});

httpServer.listen(PORT, () => {
  console.log(`mochi server on ws://localhost:${PORT}`);
});
