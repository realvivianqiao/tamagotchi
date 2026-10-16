import { WebSocketServer } from "ws";
import { createServer } from "http";
import { mkdir, readFile, writeFile } from "fs/promises";
import { join, extname, dirname } from "path";
import { fileURLToPath } from "url";
import {
  supabaseEnabled,
  loadBondsFromSupabase,
  saveBondToSupabase,
  renameDeviceOnBonds,
  upsertPlayer,
  getPlayer,
  appendFriendToPlayer,
} from "./db.js";

const PORT = Number(process.env.PORT || 3847);
const __dirname = fileURLToPath(new URL(".", import.meta.url));
const staticRoots = [join(__dirname, "public"), __dirname];
// Local file fallback when Supabase isn't configured.
const DATA_DIR = process.env.MOCHI_DATA_DIR || "/tmp";
const STORE = join(DATA_DIR, "mochi-invites.json");
const WAITING_TTL_MS = 7 * 24 * 60 * 60 * 1000; // unclaimed invite
const BOND_TTL_MS = 90 * 24 * 60 * 60 * 1000; // claimed bond record
const EMPTY_ROOM_TTL_MS = 2 * 60 * 60 * 1000;

/** Live WS rooms (ephemeral — fine to lose; clients re-attach) */
const rooms = new Map();
/** Invite / bond directory — best-effort durable on disk */
/** @type {Map<string, {hostName:?string, guestName:?string, hostDeviceId:?string, guestDeviceId:?string, fullness:number, happiness:number, createdAt:number, bondedAt:?number}>} */
const invites = new Map();

const CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
function isValidCode(c) {
  return typeof c === "string" && c.length === 6 && [...c].every((ch) => CODE_ALPHABET.includes(ch));
}

const mime = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".zip": "application/zip",
  ".ico": "image/x-icon",
  ".svg": "image/svg+xml",
  ".txt": "text/plain; charset=utf-8",
};

function code() {
  let out = "";
  for (let i = 0; i < 6; i++) out += CODE_ALPHABET[Math.floor(Math.random() * CODE_ALPHABET.length)];
  return out;
}

function uniqueCode() {
  let c;
  do c = code();
  while (rooms.has(c) || invites.has(c));
  return c;
}

function inviteAlive(inv, now = Date.now()) {
  if (!inv) return false;
  // Standing personal share-code — stays open so a group chat can all join it.
  if (inv.personalHub) {
    return now - (inv.createdAt || 0) < BOND_TTL_MS;
  }
  // Bonded once a guest name or guest device is locked in.
  if (inv.guestName || inv.guestDeviceId) {
    const t = inv.bondedAt || inv.createdAt || 0;
    return now - t < BOND_TTL_MS;
  }
  return now - (inv.createdAt || 0) < WAITING_TTL_MS;
}

function isBonded(inv) {
  if (inv?.personalHub) return false;
  return Boolean(inv && (inv.guestDeviceId || inv.guestName));
}

function findPersonalHub(deviceId) {
  if (!deviceId) return null;
  for (const [c, inv] of invites) {
    if (inv.personalHub && inv.hostDeviceId === deviceId) return { code: c, inv };
  }
  return null;
}

function findPairBond(hostDeviceId, guestDeviceId) {
  if (!hostDeviceId || !guestDeviceId) return null;
  for (const [c, inv] of invites) {
    if (inv.personalHub) continue;
    if (inv.hostDeviceId === hostDeviceId && inv.guestDeviceId === guestDeviceId) {
      return { code: c, inv };
    }
  }
  return null;
}

async function loadInvites() {
  if (supabaseEnabled) {
    const map = await loadBondsFromSupabase();
    if (map) {
      const now = Date.now();
      for (const [c, inv] of map) {
        if (inviteAlive(inv, now)) invites.set(c, inv);
      }
      console.log(`loaded ${invites.size} bonds from supabase`);
      return;
    }
  }
  try {
    await mkdir(dirname(STORE), { recursive: true });
    const raw = JSON.parse(await readFile(STORE, "utf8"));
    const now = Date.now();
    for (const [c, inv] of Object.entries(raw || {})) {
      if (inviteAlive(inv, now)) invites.set(c, inv);
    }
    console.log(`loaded ${invites.size} invites from ${STORE}`);
  } catch {
    /* first boot */
  }
}

async function saveInvites() {
  if (supabaseEnabled) {
    await Promise.all([...invites.entries()].map(([c, inv]) => saveBondToSupabase(c, inv)));
    return;
  }
  const obj = Object.fromEntries(invites);
  try {
    await mkdir(dirname(STORE), { recursive: true });
    await writeFile(STORE, JSON.stringify(obj, null, 0));
  } catch (e) {
    console.warn("save invites failed", e.message);
  }
}

/** Upsert a bond/invite record from client memory (source of truth after redeploys). */
function upsertInvite(
  c,
  {
    hostName,
    guestName,
    hostDeviceId,
    guestDeviceId,
    fullness,
    happiness,
    personalHub,
    preserveGuest = true,
  },
) {
  const prev = invites.get(c);
  const inv = {
    hostName: hostName || prev?.hostName || null,
    guestName: preserveGuest
      ? guestName || prev?.guestName || null
      : guestName ?? null,
    hostDeviceId: hostDeviceId || prev?.hostDeviceId || null,
    guestDeviceId: preserveGuest
      ? guestDeviceId || prev?.guestDeviceId || null
      : guestDeviceId ?? null,
    personalHub: personalHub ?? prev?.personalHub ?? false,
    fullness: Number.isFinite(fullness) ? fullness : prev?.fullness ?? 80,
    happiness: Number.isFinite(happiness) ? happiness : prev?.happiness ?? 80,
    createdAt: prev?.createdAt || Date.now(),
    bondedAt: prev?.bondedAt || null,
  };
  if (inv.personalHub) {
    inv.guestName = null;
    inv.guestDeviceId = null;
    inv.bondedAt = null;
  } else if ((inv.hostName && inv.guestName) || inv.guestDeviceId) {
    if (!inv.bondedAt) inv.bondedAt = Date.now();
  }
  invites.set(c, inv);
  return inv;
}

/** Keep in-memory bond names in sync when a device renames. */
function renameDeviceInMemory(deviceId, newName) {
  if (!deviceId || !newName) return;
  for (const inv of invites.values()) {
    if (inv.hostDeviceId === deviceId) inv.hostName = newName;
    if (inv.guestDeviceId === deviceId) inv.guestName = newName;
  }
}

function ensureRoomMaps(room) {
  if (!room.species) room.species = new Map(); // displayName -> species
  if (!room.stats) room.stats = new Map(); // displayName -> {fullness,happiness,updatedAt}
}

function memberStats(room, name) {
  ensureRoomMaps(room);
  if (!name) return null;
  return room.stats.get(name) || null;
}

function roomPayload(room, self) {
  ensureRoomMaps(room);
  const online = [...room.members.values()];
  const others = [...room.members.entries()]
    .filter(([ws]) => ws !== self)
    .map(([, name]) => name);
  const partner = others[0] || null;
  const pStats = memberStats(room, partner);
  // Prefer the partner's own last-reported stats — never the shared leftover blob.
  const fullness = pStats?.fullness ?? room.fullness;
  const happiness = pStats?.happiness ?? room.happiness;
  return {
    type: "room",
    code: room.code,
    fullness,
    happiness,
    updatedAt: room.updatedAt,
    you: room.members.get(self) || "",
    partner,
    partnerSpecies: partner ? room.species.get(partner) || "dog" : null,
    partnerOnline: others.length > 0,
    online,
    members: online,
  }; // `code` lets multi-friend clients update the right person
}

function notifyDevice(deviceId, msg) {
  if (!deviceId || !wss) return;
  for (const client of wss.clients) {
    if (client.readyState === 1 && client.deviceId === deviceId) send(client, msg);
  }
}

function send(ws, msg) {
  if (ws.readyState === 1) ws.send(JSON.stringify(msg));
}

function broadcast(room, msg, except = null) {
  for (const ws of room.members.keys()) {
    if (ws !== except) send(ws, msg);
  }
}

/**
 * Live rooms are ephemeral. Knowing a valid 6-char code (stored on each Mac) is enough
 * to recreate the room after a server wipe — bonds are client-owned.
 */
function ensureRoom(code, { createIfMissing = false } = {}) {
  let room = rooms.get(code);
  if (room) {
    ensureRoomMaps(room);
    return room;
  }
  const inv = invites.get(code);
  if (!inv && !createIfMissing) return null;
  room = {
    code,
    fullness: inv?.fullness ?? 80,
    happiness: inv?.happiness ?? 80,
    updatedAt: Date.now(),
    emptySince: Date.now(),
    members: new Map(),
    species: new Map(),
    stats: new Map(),
  };
  if (inv?.hostName) {
    room.stats.set(inv.hostName, {
      fullness: inv.fullness,
      happiness: inv.happiness,
      updatedAt: inv.createdAt || Date.now(),
    });
  }
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
    if (!inviteAlive(inv, now)) invites.delete(c);
  }
  for (const [c, room] of rooms) {
    if (room.members.size > 0) continue;
    const idle = room.emptySince || room.updatedAt || 0;
    if (now - idle > EMPTY_ROOM_TTL_MS) rooms.delete(c);
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
      if (extname(safe) === ".zip") headers["content-disposition"] = 'attachment; filename="CoPet.zip"';
      // Clients poll these to auto-update — never serve a stale copy.
      if (rel === "version.json" || rel === "appcast.xml") {
        headers["cache-control"] = "no-store";
      }
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

  // Create / restore invite. personal:true → standing share-code (same forever, many can claim).
  if (req.method === "POST" && url === "/api/invite") {
    const body = await readJson(req);
    const name = String(body.name || "friend").slice(0, 24);
    const deviceId = String(body.deviceId || "").slice(0, 64) || null;
    const wanted = String(body.code || "")
      .toUpperCase()
      .replace(/[^A-Z0-9]/g, "")
      .slice(0, 6);
    const usable = isValidCode(wanted);
    const personal = Boolean(body.personal);

    // One device = one permanent share code for group chats.
    if (personal) {
      const existing = findPersonalHub(deviceId);
      if (existing) {
        existing.inv.hostName = name;
        if (deviceId) existing.inv.hostDeviceId = deviceId;
        existing.inv.personalHub = true;
        existing.inv.guestName = null;
        existing.inv.guestDeviceId = null;
        existing.inv.bondedAt = null;
        ensureRoom(existing.code, { createIfMissing: true });
        await saveInvites();
        return json(res, 200, {
          code: existing.code,
          personal: true,
          hostName: name,
        });
      }
      const c = usable ? wanted : uniqueCode();
      const prev = invites.get(c);
      if (prev && !prev.personalHub && isBonded(prev) && prev.hostDeviceId !== deviceId) {
        return json(res, 409, { error: "code taken", code: c });
      }
      const inv = upsertInvite(c, {
        hostName: name,
        hostDeviceId: deviceId,
        guestName: null,
        guestDeviceId: null,
        fullness: body.fullness,
        happiness: body.happiness,
        personalHub: true,
        preserveGuest: false,
      });
      ensureRoom(c, { createIfMissing: true });
      await saveInvites();
      return json(res, 200, { code: c, personal: true, hostName: inv.hostName });
    }

    const c = usable ? wanted : uniqueCode();
    const prev = invites.get(c);
    // If this code is already bonded to someone else, don't let a new invite wipe it.
    if (usable && isBonded(prev)) {
      const sameHost =
        (deviceId && prev.hostDeviceId === deviceId) ||
        (!deviceId && prev.hostName === name);
      if (!sameHost) {
        return json(res, 409, { error: "already bonded", code: c });
      }
      // Host re-advertising an existing bond — keep guest lock, refresh host name/device.
      const inv = upsertInvite(c, {
        hostName: name,
        hostDeviceId: deviceId,
        fullness: body.fullness,
        happiness: body.happiness,
        preserveGuest: true,
      });
      ensureRoom(c, { createIfMissing: true });
      await saveInvites();
      return json(res, 200, {
        code: c,
        hostName: inv.hostName,
        guestName: inv.guestName,
        bonded: true,
      });
    }
    const inv = upsertInvite(c, {
      hostName: name,
      hostDeviceId: deviceId,
      guestName: usable ? null : undefined,
      guestDeviceId: usable ? null : undefined,
      fullness: body.fullness,
      happiness: body.happiness,
      preserveGuest: !usable,
    });
    if (usable && !isBonded(inv)) {
      inv.guestName = null;
      inv.guestDeviceId = null;
      inv.bondedAt = null;
    }
    if (deviceId) inv.hostDeviceId = deviceId;
    const room = ensureRoom(c, { createIfMissing: true });
    if (room) {
      room.stats.set(name, {
        fullness: inv.fullness,
        happiness: inv.happiness,
        updatedAt: Date.now(),
      });
    }
    await saveInvites();
    return json(res, 200, { code: c });
  }

  // Already-bonded clients rehydrate the server record after a wipe.
  if (req.method === "POST" && url === "/api/restore") {
    const body = await readJson(req);
    const c = String(body.code || "").toUpperCase().replace(/[^A-Z0-9]/g, "");
    const name = String(body.name || "friend").slice(0, 24);
    const deviceId = String(body.deviceId || "").slice(0, 64) || null;
    const partner = String(body.partnerName || "").slice(0, 24);
    if (!isValidCode(c)) return json(res, 400, { error: "bad code" });
    const prev = invites.get(c);
    let hostName = prev?.hostName || name;
    let guestName = prev?.guestName || null;
    let hostDeviceId = prev?.hostDeviceId || null;
    let guestDeviceId = prev?.guestDeviceId || null;
    if (deviceId && prev?.hostDeviceId === deviceId) {
      hostName = name;
      hostDeviceId = deviceId;
      if (partner && partner !== name) guestName = partner;
    } else if (deviceId && prev?.guestDeviceId === deviceId) {
      guestName = name;
      guestDeviceId = deviceId;
      if (partner && partner !== name) hostName = partner;
    } else if (hostName === name) {
      hostDeviceId = deviceId || hostDeviceId;
      if (partner && partner !== name) guestName = partner;
    } else {
      guestName = name;
      guestDeviceId = deviceId || guestDeviceId;
      if (partner && partner !== name) hostName = partner;
    }
    const inv = upsertInvite(c, {
      hostName,
      guestName,
      hostDeviceId,
      guestDeviceId,
      fullness: body.fullness,
      happiness: body.happiness,
      preserveGuest: true,
    });
    if (inv.hostName && inv.guestName) inv.bondedAt = inv.bondedAt || Date.now();
    ensureRoom(c, { createIfMissing: true });
    await saveInvites();
    return json(res, 200, {
      code: c,
      hostName: inv.hostName,
      guestName: inv.guestName,
      restored: true,
    });
  }

  // Claim a code. Personal hubs stay open — each new friend gets a private pair room.
  if (req.method === "POST" && url === "/api/claim") {
    const body = await readJson(req);
    const c = String(body.code || "").toUpperCase().replace(/[^A-Z0-9]/g, "");
    const name = String(body.name || "friend").slice(0, 24);
    const deviceId = String(body.deviceId || "").slice(0, 64) || null;
    const inv = invites.get(c);
    if (!inv) return json(res, 404, { error: "room not found", code: c });
    if (deviceId && inv.hostDeviceId && inv.hostDeviceId === deviceId) {
      return json(res, 400, { error: "that's your own invite", code: c });
    }

    // Standing share-code: many people can claim the same code to find this host.
    if (inv.personalHub) {
      const species = String(body.species || "dog").slice(0, 12);
      const existing = findPairBond(inv.hostDeviceId, deviceId);
      if (existing) {
        existing.inv.guestName = name;
        await saveInvites();
        ensureRoom(existing.code, { createIfMissing: true });
        return json(res, 200, {
          code: existing.code,
          hostName: inv.hostName,
          guestName: name,
          fullness: existing.inv.fullness,
          happiness: existing.inv.happiness,
          alreadyBonded: true,
          shareCode: c,
        });
      }
      const pair = uniqueCode();
      const pairInv = upsertInvite(pair, {
        hostName: inv.hostName,
        guestName: name,
        hostDeviceId: inv.hostDeviceId,
        guestDeviceId: deviceId,
        fullness: Number.isFinite(body.fullness) ? body.fullness : inv.fullness,
        happiness: Number.isFinite(body.happiness) ? body.happiness : inv.happiness,
        personalHub: false,
        preserveGuest: false,
      });
      pairInv.bondedAt = Date.now();
      ensureRoom(pair, { createIfMissing: true });
      await saveInvites();
      // Host learns about the new friend (cloud + live socket).
      const hostFriend = {
        code: pair,
        partnerName: name,
        fullness: pairInv.fullness,
        happiness: pairInv.happiness,
        lastActivity: "just bonded",
        species,
      };
      await appendFriendToPlayer(inv.hostDeviceId, hostFriend);
      notifyDevice(inv.hostDeviceId, {
        type: "bond",
        code: pair,
        partnerName: name,
        species,
        fullness: pairInv.fullness,
        happiness: pairInv.happiness,
        shareCode: c,
      });
      return json(res, 200, {
        code: pair,
        hostName: inv.hostName,
        guestName: name,
        fullness: pairInv.fullness,
        happiness: pairInv.happiness,
        shareCode: c,
      });
    }

    if (inv.guestDeviceId) {
      if (deviceId && inv.guestDeviceId === deviceId) {
        inv.guestName = name;
        await saveInvites();
        ensureRoom(c, { createIfMissing: true });
        return json(res, 200, {
          code: c,
          hostName: inv.hostName,
          guestName: name,
          fullness: inv.fullness,
          happiness: inv.happiness,
          alreadyBonded: true,
        });
      }
      return json(res, 409, { error: "already bonded", code: c });
    }
    // Legacy name lock (no device id yet) — still bond-once.
    if (inv.guestName && inv.guestName !== name) {
      return json(res, 409, { error: "already bonded", code: c });
    }
    inv.guestName = name;
    if (deviceId) inv.guestDeviceId = deviceId;
    inv.bondedAt = Date.now();
    ensureRoom(c, { createIfMissing: true });
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
    return json(res, 200, {
      ok: true,
      invites: invites.size,
      rooms: rooms.size,
      store: supabaseEnabled ? "supabase" : STORE,
      supabase: supabaseEnabled,
    });
  }

  // Pull cloud profile + friends. deviceId is the stable pad key (one Mac = one user).
  if (req.method === "GET" && url === "/api/me") {
    const q = new URL(req.url || "/", "http://x").searchParams;
    const deviceId = String(q.get("deviceId") || "").slice(0, 64);
    if (!deviceId) return json(res, 400, { error: "deviceId required" });
    if (!supabaseEnabled) return json(res, 503, { error: "supabase not configured" });
    const row = await getPlayer(deviceId);
    // 404 → client cloudPush registers the pad with the real display name.
    if (!row) return json(res, 404, { error: "not found", deviceId });
    return json(res, 200, {
      deviceId: row.device_id,
      displayName: row.display_name,
      species: row.species,
      fullness: row.fullness,
      happiness: row.happiness,
      friends: row.friends || [],
      activeCode: row.active_code,
      updatedAt: row.updated_at,
    });
  }

  // Push cloud profile + friends — durable pad + bond history for this device.
  if (req.method === "POST" && url === "/api/me") {
    const body = await readJson(req);
    const deviceId = String(body.deviceId || "").slice(0, 64);
    if (!deviceId) return json(res, 400, { error: "deviceId required" });
    if (!supabaseEnabled) return json(res, 503, { error: "supabase not configured" });
    const displayName = String(body.displayName || "me").slice(0, 24);
    const prev = await getPlayer(deviceId);
    const friends = Array.isArray(body.friends)
      ? body.friends.map((f) => ({
          code: String(f.code || "").toUpperCase().slice(0, 6),
          partnerName: String(f.partnerName || "friend").slice(0, 24),
          online: false,
          waiting: Boolean(f.waiting),
          fullness: Number(f.fullness) || 80,
          happiness: Number(f.happiness) || 80,
          lastActivity: f.lastActivity ? String(f.lastActivity).slice(0, 80) : null,
          species: String(f.species || "dog").slice(0, 12),
        }))
      : [];
    const result = await upsertPlayer({
      deviceId,
      displayName,
      species: body.species,
      fullness: body.fullness,
      happiness: body.happiness,
      friends,
      activeCode: body.activeCode,
    });
    if (!result.ok) return json(res, 500, { error: result.error });
    // Name change → update every bond row where this device is host or guest.
    const renamed = prev && prev.display_name !== displayName;
    if (renamed) {
      renameDeviceInMemory(deviceId, displayName);
      await renameDeviceOnBonds(deviceId, displayName);
    }
    // Warm invite directory from this pad's friend list (never wipe an existing guest lock).
    for (const f of friends) {
      if (!isValidCode(f.code)) continue;
      const existing = invites.get(f.code);
      if (f.waiting) {
        if (isBonded(existing) && existing.hostDeviceId && existing.hostDeviceId !== deviceId) {
          continue;
        }
        if (isBonded(existing) && existing.hostDeviceId === deviceId) {
          upsertInvite(f.code, {
            hostName: displayName,
            hostDeviceId: deviceId,
            fullness: f.fullness,
            happiness: f.happiness,
            preserveGuest: true,
          });
        } else {
          upsertInvite(f.code, {
            hostName: displayName,
            hostDeviceId: deviceId,
            guestName: null,
            guestDeviceId: null,
            fullness: f.fullness,
            happiness: f.happiness,
            preserveGuest: false,
          });
        }
      } else {
        const asHost =
          !existing?.guestDeviceId ||
          existing.hostDeviceId === deviceId ||
          existing.hostName === displayName;
        if (asHost) {
          upsertInvite(f.code, {
            hostName: displayName,
            guestName: f.partnerName,
            hostDeviceId: deviceId,
            fullness: f.fullness,
            happiness: f.happiness,
            preserveGuest: true,
          });
        } else {
          upsertInvite(f.code, {
            hostName: existing?.hostName || f.partnerName,
            guestName: displayName,
            guestDeviceId: deviceId,
            fullness: f.fullness,
            happiness: f.happiness,
            preserveGuest: true,
          });
        }
        const inv = invites.get(f.code);
        if (inv && !inv.bondedAt) inv.bondedAt = Date.now();
      }
    }
    await saveInvites();
    return json(res, 200, { ok: true, deviceId, friends: friends.length, renamed: Boolean(renamed) });
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

    // Identify this socket's device (so we can push "someone claimed your code").
    if (msg.type === "hello") {
      ws.deviceId = String(msg.deviceId || "").slice(0, 64) || null;
      return send(ws, { type: "hello_ok", deviceId: ws.deviceId });
    }

    // Attach to a friend room (one socket can be in many rooms).
    // Valid codes recreate rooms even after a wipe — bond lives on the client + Supabase.
    if (msg.type === "attach" || msg.type === "join") {
      const c = String(msg.code || "").toUpperCase().replace(/[^A-Z0-9]/g, "");
      const name = String(msg.name || "friend").slice(0, 24);
      const deviceId = String(msg.deviceId || "").slice(0, 64) || null;
      const species = String(msg.species || "dog").toLowerCase().slice(0, 12);
      const partnerName = String(msg.partnerName || "").slice(0, 24);
      if (!isValidCode(c)) return send(ws, { type: "error", text: "bad code", code: c });
      // Seed directory from client memory when the server forgot the bond.
      if (!invites.has(c) || (partnerName && !invites.get(c)?.guestName)) {
        upsertInvite(c, {
          hostName: invites.get(c)?.hostName || name,
          guestName: partnerName || invites.get(c)?.guestName || null,
          hostDeviceId: invites.get(c)?.hostDeviceId || deviceId,
          fullness: Number.isFinite(msg.fullness) ? msg.fullness : undefined,
          happiness: Number.isFinite(msg.happiness) ? msg.happiness : undefined,
        });
        saveInvites();
      }
      const room = ensureRoom(c, { createIfMissing: true });
      if (!room) return send(ws, { type: "error", text: "room not found", code: c });
      if (room.members.size >= 2 && ![...room.members.values()].includes(name)) {
        // Allow re-attach if same device reconnects under a new display name.
        const inv = invites.get(c);
        const known =
          deviceId &&
          (inv?.hostDeviceId === deviceId || inv?.guestDeviceId === deviceId);
        if (!known) {
          return send(ws, { type: "error", text: "already bonded (2 people max)", code: c });
        }
      }
      ensureRoomMaps(room);
      ws.deviceId = deviceId;
      for (const [peer, n] of [...room.members]) {
        if ((n === name || (deviceId && peer.deviceId === deviceId)) && peer !== ws) {
          room.members.delete(peer);
          if (peer.rooms) peer.rooms.delete(c);
        }
      }
      leaveRoom(ws, c);
      room.members.set(ws, name);
      room.species.set(name, species);
      room.emptySince = null;
      room.updatedAt = Date.now();
      ws.rooms.set(c, name);
      ws.room = room;
      const inv = invites.get(c);
      if (inv) {
        if (deviceId && inv.hostDeviceId === deviceId) {
          inv.hostName = name;
        } else if (deviceId && inv.guestDeviceId === deviceId) {
          inv.guestName = name;
        } else if (!inv.hostName) {
          inv.hostName = name;
          if (deviceId) inv.hostDeviceId = deviceId;
        } else if (name !== inv.hostName) {
          inv.guestName = name;
          if (deviceId) inv.guestDeviceId = deviceId;
        }
        if (inv.hostName && inv.guestName) inv.bondedAt = inv.bondedAt || Date.now();
        saveInvites();
      }
      notifyRoom(room);
      return;
    }

    // Display-name change: update bond rows + tell partners so their Friends list stays current.
    if (msg.type === "rename") {
      const name = String(msg.name || "").slice(0, 24);
      const deviceId = String(msg.deviceId || "").slice(0, 64) || ws.deviceId || null;
      if (!name) return;
      ws.deviceId = deviceId || ws.deviceId;
      if (deviceId) {
        renameDeviceInMemory(deviceId, name);
        renameDeviceOnBonds(deviceId, name).catch(() => {});
        saveInvites();
      }
      for (const [c, oldName] of [...ws.rooms]) {
        const room = rooms.get(c);
        if (!room || !room.members.has(ws)) continue;
        ensureRoomMaps(room);
        const prevStats = room.stats.get(oldName);
        const prevSpecies = room.species.get(oldName);
        room.members.set(ws, name);
        ws.rooms.set(c, name);
        if (prevStats) {
          room.stats.delete(oldName);
          room.stats.set(name, prevStats);
        }
        if (prevSpecies) {
          room.species.delete(oldName);
          room.species.set(name, prevSpecies);
        }
        broadcast(
          room,
          { type: "rename", code: c, name, from: oldName, deviceId: deviceId || null },
          ws,
        );
        notifyRoom(room);
      }
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
        species: new Map(),
        stats: new Map([
          [name, { fullness: inv.fullness, happiness: inv.happiness, updatedAt: Date.now() }],
        ]),
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
      ensureRoomMaps(room);
      const fromName = room.members.get(ws) || "";
      const at = Number(msg.updatedAt) || Date.now();
      const action = msg.action ? String(msg.action).slice(0, 24) : null;
      const f = Number.isFinite(msg.fullness) ? Math.max(0, Math.min(100, msg.fullness)) : null;
      const h = Number.isFinite(msg.happiness) ? Math.max(0, Math.min(100, msg.happiness)) : null;

      // Stats always belong to the sender's own pet (per-member), never a shared blob
      // that the other person's FriendBond / applyRoom can steal.
      if (fromName && (f != null || h != null)) {
        const prev = room.stats.get(fromName) || { fullness: 80, happiness: 80, updatedAt: 0 };
        if (at >= (prev.updatedAt || 0)) {
          room.stats.set(fromName, {
            fullness: f ?? prev.fullness,
            happiness: h ?? prev.happiness,
            updatedAt: at,
          });
        }
      }
      if (msg.species && fromName) {
        room.species.set(fromName, String(msg.species).toLowerCase().slice(0, 12));
      }
      // Keep legacy room.fullness as the sender's latest for invite warm-up only.
      if (f != null) room.fullness = f;
      if (h != null) room.happiness = h;
      if (at >= room.updatedAt) room.updatedAt = at;
      const inv = invites.get(room.code);
      if (inv && fromName && fromName === inv.hostName) {
        const st = room.stats.get(fromName);
        if (st) {
          inv.fullness = st.fullness;
          inv.happiness = st.happiness;
        }
      }

      const mine = memberStats(room, fromName);
      const payload = {
        type: "sync",
        code: room.code,
        fullness: mine?.fullness ?? room.fullness,
        happiness: mine?.happiness ?? room.happiness,
        updatedAt: at,
        action,
        from: fromName,
        species: msg.species || (fromName && room.species.get(fromName)) || null,
      };
      // Don't echo actions back to the actor — local UI already recorded "you: pet".
      // Stats-only syncs still fan out to peers (and skip the sender).
      broadcast(room, payload, ws);
      return;
    }

    if (msg.type === "ping") return send(ws, { type: "pong" });
  });

  ws.on("close", () => leave(ws));
});

await loadInvites();
httpServer.listen(PORT, () => {
  console.log(`CoPet site + api + ws on :${PORT}`);
});
