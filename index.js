import { WebSocketServer } from "ws";
import { createServer } from "http";
import { readFile, writeFile } from "fs/promises";
import { join, extname } from "path";
import { fileURLToPath } from "url";

const PORT = Number(process.env.PORT || 3847);
const __dirname = fileURLToPath(new URL(".", import.meta.url));
const staticRoots = [join(__dirname, "public"), __dirname];
const STORE = "/tmp/mochi-invites.json";
const ROOM_TTL_MS = 2 * 60 * 60 * 1000; // 2 hours

/** Live WS rooms */
const rooms = new Map();
/** Durable invites that survive deploys/restarts on this box */
/** @type {Map<string, {hostName:string, guestName:?string, fullness:number, happiness:number, createdAt:number}>} */
const invites = new Map();

const mime = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".zip": "application/zip",
  ".ico": "image/x-icon",
  ".svg": "image/svg+xml",
  ".txt": "text/plain; charset=utf-8",
};

function code() {
  const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  let out = "";
  for (let i = 0; i < 6; i++) out += alphabet[Math.floor(Math.random() * alphabet.length)];
  return out;
}

function uniqueCode() {
  let c;
  do c = code();
  while (rooms.has(c) || invites.has(c));
  return c;
}

async function loadInvites() {
  try {
    const raw = JSON.parse(await readFile(STORE, "utf8"));
    const now = Date.now();
    for (const [c, inv] of Object.entries(raw || {})) {
      if (now - (inv.createdAt || 0) < ROOM_TTL_MS) invites.set(c, inv);
    }
    console.log(`loaded ${invites.size} invites from disk`);
  } catch {
    /* first boot */
  }
}

async function saveInvites() {
  const obj = Object.fromEntries(invites);
  try {
    await writeFile(STORE, JSON.stringify(obj));
  } catch (e) {
    console.warn("save invites failed", e.message);
  }
}

function roomPayload(room, self) {
  const online = [...room.members.values()];
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
    partnerOnline: others.length > 0,
    online,
    members: online,
  }; // `code` lets multi-friend clients update the right person
}

function send(ws, msg) {
  if (ws.readyState === 1) ws.send(JSON.stringify(msg));
}

function broadcast(room, msg, except = null) {
  for (const ws of room.members.keys()) {
    if (ws !== except) send(ws, msg);
  }
}

function ensureRoom(code) {
  let room = rooms.get(code);
  if (room) return room;
  const inv = invites.get(code);
  if (!inv) return null;
  room = {
    code,
    fullness: inv.fullness,
    happiness: inv.happiness,
    updatedAt: Date.now(),
    emptySince: Date.now(),
    members: new Map(),
  };
  rooms.set(code, room);
  return room;
}

function notifyRoom(room, leavingName = null) {
  for (const peer of room.members.keys()) {
    send(peer, roomPayload(room, peer));
    send(peer, {
      type: "presence",
      code: room.code,
      partnerOnline: room.members.size > 1,
      partner: [...room.members.values()].find((n) => n !== room.members.get(peer)) || leavingName,
      online: [...room.members.values()],
    });
  }
}

/** Leave one room (supports multi-friend: one socket in many rooms). */
function leaveRoom(ws, code) {
  if (!ws.rooms) ws.rooms = new Map();
  const room = rooms.get(code);
  if (!room || !room.members.has(ws)) {
    ws.rooms.delete(code);
    return;
  }
  const leavingName = room.members.get(ws);
  room.members.delete(ws);
  ws.rooms.delete(code);
  if (ws.room === room) ws.room = ws.rooms.size ? rooms.get([...ws.rooms.keys()][0]) : null;
  if (room.members.size === 0) {
    room.emptySince = Date.now();
    return;
  }
  room.emptySince = null;
  notifyRoom(room, leavingName);
}

function leave(ws) {
  if (!ws.rooms) ws.rooms = new Map();
  for (const code of [...ws.rooms.keys()]) leaveRoom(ws, code);
  ws.room = null;
}

setInterval(() => {
  const now = Date.now();
  for (const [c, inv] of invites) {
    if (now - inv.createdAt > ROOM_TTL_MS) invites.delete(c);
  }
  for (const [c, room] of rooms) {
    if (room.members.size > 0) continue;
    const idle = room.emptySince || room.updatedAt || 0;
    if (now - idle > ROOM_TTL_MS) rooms.delete(c);
  }
  saveInvites();
}, 60_000).unref?.();

async function readJson(req) {
  const chunks = [];
  for await (const c of req) chunks.push(c);
  if (!chunks.length) return {};
  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch {
    return {};
  }
}

function json(res, status, body) {
  const data = JSON.stringify(body);
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "access-control-allow-origin": "*",
  });
  res.end(data);
}

async function serveStatic(req, res) {
  let path = (req.url || "/").split("?")[0];
  if (path === "/") path = "/index.html";
  const rel = path.replace(/^\/+/, "");
  for (const root of staticRoots) {
    const safe = join(root, rel);
    if (!safe.startsWith(root)) continue;
    try {
      const data = await readFile(safe);
      const type = mime[extname(safe)] || "application/octet-stream";
      const headers = { "content-type": type };
      if (extname(safe) === ".zip") headers["content-disposition"] = 'attachment; filename="Mochi.zip"';
      res.writeHead(200, headers);
      return res.end(data);
    } catch {
      /* next */
    }
  }
  res.writeHead(404, { "content-type": "text/plain; charset=utf-8" });
  res.end("not found\n");
}

const httpServer = createServer(async (req, res) => {
  const url = (req.url || "/").split("?")[0];

  if (req.method === "OPTIONS") {
    res.writeHead(204, {
      "access-control-allow-origin": "*",
      "access-control-allow-methods": "GET,POST,OPTIONS",
      "access-control-allow-headers": "content-type",
    });
    return res.end();
  }

  // Durable invite (survives WS drops + most restarts on same instance)
  if (req.method === "POST" && url === "/api/invite") {
    const body = await readJson(req);
    const name = String(body.name || "friend").slice(0, 24);
    const c = uniqueCode();
    const inv = {
      hostName: name,
      guestName: null,
      fullness: Number.isFinite(body.fullness) ? body.fullness : 80,
      happiness: Number.isFinite(body.happiness) ? body.happiness : 80,
      createdAt: Date.now(),
    };
    invites.set(c, inv);
    // also warm a live room so WS attach is instant
    rooms.set(c, {
      code: c,
      fullness: inv.fullness,
      happiness: inv.happiness,
      updatedAt: Date.now(),
      emptySince: Date.now(),
      members: new Map(),
    });
    await saveInvites();
    return json(res, 200, { code: c });
  }

  if (req.method === "POST" && url === "/api/claim") {
    const body = await readJson(req);
    const c = String(body.code || "").toUpperCase().replace(/[^A-Z0-9]/g, "");
    const name = String(body.name || "friend").slice(0, 24);
    const inv = invites.get(c);
    if (!inv) return json(res, 404, { error: "room not found", code: c });
    if (inv.guestName && inv.guestName !== name) {
      // allow reclaim by same name; block third person
      return json(res, 409, { error: "room full", code: c });
    }
    inv.guestName = name;
    await saveInvites();
    return json(res, 200, {
      code: c,
      hostName: inv.hostName,
      guestName: name,
      fullness: inv.fullness,
      happiness: inv.happiness,
    });
  }

  if (req.method === "GET" && url === "/api/health") {
    return json(res, 200, { ok: true, invites: invites.size, rooms: rooms.size });
  }

  return serveStatic(req, res);
});

const wss = new WebSocketServer({ server: httpServer });

wss.on("connection", (ws) => {
  ws.room = null;
  ws.rooms = new Map(); // code -> display name in that room

  ws.on("message", (raw) => {
    let msg;
    try {
      msg = JSON.parse(String(raw));
    } catch {
      return send(ws, { type: "error", text: "bad json" });
    }

    // Attach to a friend room (one socket can be in many rooms)
    if (msg.type === "attach" || msg.type === "join") {
      const c = String(msg.code || "").toUpperCase().replace(/[^A-Z0-9]/g, "");
      const name = String(msg.name || "friend").slice(0, 24);
      const room = ensureRoom(c);
      if (!room) return send(ws, { type: "error", text: "room not found", code: c });
      if (room.members.size >= 2 && ![...room.members.values()].includes(name)) {
        return send(ws, { type: "error", text: "already bonded (2 people max)", code: c });
      }
      // replace existing socket for same name in THIS room only
      for (const [peer, n] of [...room.members]) {
        if (n === name && peer !== ws) {
          room.members.delete(peer);
          if (peer.rooms) peer.rooms.delete(c);
        }
      }
      leaveRoom(ws, c);
      room.members.set(ws, name);
      room.emptySince = null;
      room.updatedAt = Date.now();
      ws.rooms.set(c, name);
      ws.room = room;
      const inv = invites.get(c);
      if (inv && name !== inv.hostName) inv.guestName = name;
      notifyRoom(room);
      return;
    }

    if (msg.type === "detach") {
      const c = String(msg.code || "").toUpperCase().replace(/[^A-Z0-9]/g, "");
      leaveRoom(ws, c);
      return send(ws, { type: "detached", code: c });
    }

    if (msg.type === "create") {
      const name = String(msg.name || "friend").slice(0, 24);
      const c = uniqueCode();
      const inv = {
        hostName: name,
        guestName: null,
        fullness: Number.isFinite(msg.fullness) ? msg.fullness : 80,
        happiness: Number.isFinite(msg.happiness) ? msg.happiness : 80,
        createdAt: Date.now(),
      };
      invites.set(c, inv);
      saveInvites();
      const room = {
        code: c,
        fullness: inv.fullness,
        happiness: inv.happiness,
        updatedAt: Date.now(),
        emptySince: null,
        members: new Map([[ws, name]]),
      };
      rooms.set(c, room);
      ws.rooms.set(c, name);
      ws.room = room;
      return send(ws, roomPayload(room, ws));
    }

    if (msg.type === "sync") {
      const c = String(msg.code || "").toUpperCase().replace(/[^A-Z0-9]/g, "");
      const room = (c && rooms.get(c)) || ws.room;
      if (!room || !room.members.has(ws)) return;
      const at = Number(msg.updatedAt) || Date.now();
      if (at < room.updatedAt) return send(ws, roomPayload(room, ws));
      if (Number.isFinite(msg.fullness)) room.fullness = Math.max(0, Math.min(100, msg.fullness));
      if (Number.isFinite(msg.happiness)) room.happiness = Math.max(0, Math.min(100, msg.happiness));
      room.updatedAt = at;
      const inv = invites.get(room.code);
      if (inv) {
        inv.fullness = room.fullness;
        inv.happiness = room.happiness;
      }
      broadcast(room, {
        type: "sync",
        code: room.code,
        fullness: room.fullness,
        happiness: room.happiness,
        updatedAt: room.updatedAt,
        action: msg.action || null,
        from: room.members.get(ws) || "",
      });
      return;
    }

    if (msg.type === "ping") return send(ws, { type: "pong" });
  });

  ws.on("close", () => leave(ws));
});

await loadInvites();
httpServer.listen(PORT, () => {
  console.log(`mochi site + api + ws on :${PORT}`);
});
