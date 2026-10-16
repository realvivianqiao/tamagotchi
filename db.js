/**
 * Supabase persistence for CoPet players + bonds (survives Render sleep).
 * Requires SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY (or SUPABASE_SECRET_KEY).
 * Falls back to in-memory / local file when unset.
 */
import { createClient } from "@supabase/supabase-js";
import { readFileSync, existsSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";

// Local .env (gitignored). Render injects env vars in production.
(function loadDotEnv() {
  try {
    const envPath = join(dirname(fileURLToPath(import.meta.url)), ".env");
    if (!existsSync(envPath)) return;
    for (const line of readFileSync(envPath, "utf8").split("\n")) {
      const m = line.match(/^([^#=\s]+)\s*=\s*(.*)$/);
      if (!m) continue;
      const k = m[1].trim();
      const v = m[2].trim().replace(/^["']|["']$/g, "");
      if (k && process.env[k] === undefined) process.env[k] = v;
    }
  } catch {
    /* ignore */
  }
})();

const url = (process.env.SUPABASE_URL || "").replace(/\/rest\/v1\/?$/, "").replace(/\/$/, "");
const key =
  process.env.SUPABASE_SERVICE_ROLE_KEY ||
  process.env.SUPABASE_SECRET_KEY ||
  "";

export const supabaseEnabled = Boolean(url && key);

/** @type {import('@supabase/supabase-js').SupabaseClient | null} */
export const supabase = supabaseEnabled
  ? createClient(url, key, {
      auth: { persistSession: false, autoRefreshToken: false },
    })
  : null;

if (supabaseEnabled) {
  console.log(`supabase: enabled (${url.replace(/^https?:\/\//, "").split(".")[0]}…)`);
} else {
  console.log("supabase: disabled (set SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY)");
}

export async function loadBondsFromSupabase() {
  if (!supabase) return null;
  const { data, error } = await supabase.from("mochi_bonds").select("*");
  if (error) {
    console.warn("supabase load bonds:", error.message);
    return null;
  }
  /** @type {Map<string, any>} */
  const map = new Map();
  for (const row of data || []) {
    map.set(row.code, {
      hostName: row.host_name,
      guestName: row.guest_name,
      hostDeviceId: row.host_device_id,
      guestDeviceId: row.guest_device_id,
      personalHub: Boolean(row.personal_hub),
      fullness: row.fullness ?? 80,
      happiness: row.happiness ?? 80,
      createdAt: row.created_at ? Date.parse(row.created_at) : Date.now(),
      bondedAt: row.bonded_at ? Date.parse(row.bonded_at) : null,
    });
  }
  return map;
}

export async function saveBondToSupabase(code, inv) {
  if (!supabase) return;
  const row = {
    code,
    host_name: inv.hostName ?? null,
    guest_name: inv.guestName ?? null,
    host_device_id: inv.hostDeviceId ?? null,
    guest_device_id: inv.guestDeviceId ?? null,
    personal_hub: Boolean(inv.personalHub),
    fullness: inv.fullness ?? 80,
    happiness: inv.happiness ?? 80,
    created_at: inv.createdAt ? new Date(inv.createdAt).toISOString() : new Date().toISOString(),
    bonded_at: inv.bondedAt ? new Date(inv.bondedAt).toISOString() : null,
    updated_at: new Date().toISOString(),
  };
  const { error } = await supabase.from("mochi_bonds").upsert(row, { onConflict: "code" });
  if (error) console.warn("supabase save bond:", error.message);
}

/** Append a friend row onto a player's cloud friends list (host learns about new claims). */
export async function appendFriendToPlayer(deviceId, friend) {
  if (!supabase || !deviceId || !friend?.code) return;
  const row = await getPlayer(deviceId);
  if (!row) return;
  const friends = Array.isArray(row.friends) ? [...row.friends] : [];
  if (friends.some((f) => String(f.code || "").toUpperCase() === String(friend.code).toUpperCase())) {
    return;
  }
  friends.push({
    code: String(friend.code).toUpperCase().slice(0, 6),
    partnerName: String(friend.partnerName || "friend").slice(0, 24),
    online: false,
    waiting: false,
    fullness: Number(friend.fullness) || 80,
    happiness: Number(friend.happiness) || 80,
    lastActivity: friend.lastActivity ? String(friend.lastActivity).slice(0, 80) : "new bond",
    species: String(friend.species || "dog").slice(0, 12),
  });
  await upsertPlayer({
    deviceId,
    displayName: row.display_name,
    species: row.species,
    fullness: row.fullness,
    happiness: row.happiness,
    friends,
    activeCode: row.active_code,
  });
}

/** When a device renames, keep bond host/guest names in sync. */
export async function renameDeviceOnBonds(deviceId, newName) {
  if (!supabase || !deviceId || !newName) return;
  const name = String(newName).slice(0, 24);
  for (const col of ["host_device_id", "guest_device_id"]) {
    const nameCol = col.startsWith("host") ? "host_name" : "guest_name";
    const { error } = await supabase
      .from("mochi_bonds")
      .update({ [nameCol]: name, updated_at: new Date().toISOString() })
      .eq(col, deviceId);
    if (error) console.warn(`supabase rename bonds (${col}):`, error.message);
  }
}

export async function deleteBondFromSupabase(code) {
  if (!supabase) return;
  const { error } = await supabase.from("mochi_bonds").delete().eq("code", code);
  if (error) console.warn("supabase delete bond:", error.message);
}

export async function upsertPlayer(player) {
  if (!supabase) return { ok: false, error: "supabase disabled" };
  const row = {
    device_id: player.deviceId,
    display_name: String(player.displayName || "me").slice(0, 24),
    species: String(player.species || "dog").slice(0, 12),
    fullness: Number.isFinite(player.fullness) ? player.fullness : 80,
    happiness: Number.isFinite(player.happiness) ? player.happiness : 80,
    friends: Array.isArray(player.friends) ? player.friends : [],
    active_code: player.activeCode || null,
    owner_name: player.ownerName ? String(player.ownerName).slice(0, 18) : null,
    pad_name: player.padName ? String(player.padName).slice(0, 12) : null,
    share_code: player.shareCode
      ? String(player.shareCode).toUpperCase().replace(/[^A-Z0-9]/g, "").slice(0, 6)
      : null,
    updated_at: new Date().toISOString(),
  };
  const { data, error } = await supabase
    .from("mochi_players")
    .upsert(row, { onConflict: "device_id" })
    .select()
    .maybeSingle();
  if (error) return { ok: false, error: error.message };
  return { ok: true, player: data };
}

/** Upsert mochi_users + append changelog rows when identity fields change. */
export async function upsertUserProfile(user) {
  if (!supabase) return { ok: false, error: "supabase disabled" };
  const deviceId = String(user.deviceId || "").slice(0, 64);
  if (!deviceId) return { ok: false, error: "deviceId required" };

  const next = {
    device_id: deviceId,
    share_code: user.shareCode
      ? String(user.shareCode).toUpperCase().replace(/[^A-Z0-9]/g, "").slice(0, 6)
      : null,
    owner_name: String(user.ownerName || "me").slice(0, 18),
    pad_name: String(user.padName || "Zuzu").slice(0, 12),
    species: String(user.species || "dog").slice(0, 12),
    updated_at: new Date().toISOString(),
  };

  const { data: prev } = await supabase
    .from("mochi_users")
    .select("*")
    .eq("device_id", deviceId)
    .maybeSingle();

  const row = prev
    ? next
    : { ...next, created_at: new Date().toISOString() };

  // Keep an existing unique share_code if client didn't send one.
  if (!row.share_code && prev?.share_code) row.share_code = prev.share_code;

  const { data, error } = await supabase
    .from("mochi_users")
    .upsert(row, { onConflict: "device_id" })
    .select()
    .maybeSingle();
  if (error) return { ok: false, error: error.message };

  const fields = [
    ["owner_name", prev?.owner_name, next.owner_name],
    ["pad_name", prev?.pad_name, next.pad_name],
    ["species", prev?.species, next.species],
    ["share_code", prev?.share_code, next.share_code],
  ];
  for (const [field, oldV, newV] of fields) {
    if (String(oldV || "") === String(newV || "")) continue;
    await logUserChange({
      deviceId,
      field,
      oldValue: oldV,
      newValue: newV,
      payload: { source: user.source || "cloud_push" },
    });
  }
  return { ok: true, user: data, created: !prev };
}

export async function logUserChange(chg) {
  if (!supabase) return { ok: false, error: "supabase disabled" };
  const row = {
    device_id: String(chg.deviceId || "").slice(0, 64),
    field: String(chg.field || "unknown").slice(0, 40),
    old_value: chg.oldValue != null ? String(chg.oldValue).slice(0, 80) : null,
    new_value: chg.newValue != null ? String(chg.newValue).slice(0, 80) : null,
    created_at: new Date().toISOString(),
    payload: chg.payload && typeof chg.payload === "object" ? chg.payload : {},
  };
  if (!row.device_id) return { ok: false, error: "deviceId required" };
  const { error } = await supabase.from("mochi_user_changelog").insert(row);
  if (error) {
    console.warn("supabase user changelog:", error.message);
    return { ok: false, error: error.message };
  }
  return { ok: true };
}

export async function logBindingEvent(evt) {
  if (!supabase) return { ok: false, error: "supabase disabled" };
  const row = {
    device_id: String(evt.deviceId || "").slice(0, 64),
    peer_device_id: evt.peerDeviceId ? String(evt.peerDeviceId).slice(0, 64) : null,
    pair_code: evt.pairCode
      ? String(evt.pairCode).toUpperCase().replace(/[^A-Z0-9]/g, "").slice(0, 6)
      : null,
    share_code: evt.shareCode
      ? String(evt.shareCode).toUpperCase().replace(/[^A-Z0-9]/g, "").slice(0, 6)
      : null,
    event_type: String(evt.eventType || "unknown").slice(0, 40),
    peer_name: evt.peerName ? String(evt.peerName).slice(0, 24) : null,
    created_at: new Date().toISOString(),
    payload: evt.payload && typeof evt.payload === "object" ? evt.payload : {},
  };
  if (!row.device_id) return { ok: false, error: "deviceId required" };
  const { error } = await supabase.from("mochi_binding_events").insert(row);
  if (error) {
    console.warn("supabase binding event:", error.message);
    return { ok: false, error: error.message };
  }
  return { ok: true };
}

export async function insertFeedback(fb) {
  const body = String(fb.body || "").trim().slice(0, 4000);
  if (!body) return { ok: false, error: "body required" };
  const row = {
    device_id: fb.deviceId ? String(fb.deviceId).slice(0, 64) : null,
    owner_name: fb.ownerName ? String(fb.ownerName).slice(0, 24) : null,
    body,
    app_version: fb.appVersion ? String(fb.appVersion).slice(0, 24) : null,
    created_at: new Date().toISOString(),
    payload: fb.payload && typeof fb.payload === "object" ? fb.payload : {},
  };

  // Prefer durable Supabase row when configured.
  if (supabase) {
    const { error } = await supabase.from("mochi_feedback").insert(row);
    if (!error) return { ok: true, stored: "supabase" };
    console.warn("supabase feedback:", error.message);
    // Table missing / RLS / etc — fall through to event + local file.
  }

  // Always mirror into mochi_events so feedback isn't lost when the table isn't ready.
  if (supabase) {
    const { error: evErr } = await supabase.from("mochi_events").insert({
      created_at: row.created_at,
      client_ts: row.created_at,
      owner_device_id: row.device_id,
      owner_name: row.owner_name,
      device_id: row.device_id,
      display_name: row.owner_name,
      event: "feedback_submit",
      app_version: row.app_version,
      payload: { body, ...(row.payload || {}) },
    });
    if (!evErr) return { ok: true, stored: "event" };
    console.warn("supabase feedback event:", evErr.message);
  }

  return { ok: false, error: supabase ? "feedback store failed" : "supabase disabled" };
}

export async function getPlayer(deviceId) {
  if (!supabase) return null;
  const { data, error } = await supabase
    .from("mochi_players")
    .select("*")
    .eq("device_id", deviceId)
    .maybeSingle();
  if (error) {
    console.warn("supabase get player:", error.message);
    return null;
  }
  return data;
}

const CARE_ACTIONS = new Set(["feed", "play", "pet", "poke"]);

/**
 * Increment directed friendship tallies (e.g. Vivian → Evars · poke).
 * Unique on (pair_code, actor_name, action) so both sides of a bond stay queryable.
 */
export async function bumpFriendAction(evt) {
  if (!supabase) return { ok: false, error: "supabase disabled" };
  const action = String(evt.action || "").toLowerCase().trim();
  if (!CARE_ACTIONS.has(action)) return { ok: false, error: "bad action" };
  const pairCode = String(evt.pairCode || evt.code || "")
    .toUpperCase()
    .replace(/[^A-Z0-9]/g, "")
    .slice(0, 6);
  const actorName = String(evt.actorName || "").trim().slice(0, 24);
  const peerName = String(evt.peerName || "").trim().slice(0, 24);
  if (!pairCode || !actorName || !peerName) {
    return { ok: false, error: "pair/actor/peer required" };
  }
  if (actorName.toLowerCase() === peerName.toLowerCase()) {
    return { ok: false, error: "self action" };
  }

  const actorDeviceId = evt.actorDeviceId ? String(evt.actorDeviceId).slice(0, 64) : null;
  const peerDeviceId = evt.peerDeviceId ? String(evt.peerDeviceId).slice(0, 64) : null;
  const reportedBy = evt.reportedByDeviceId
    ? String(evt.reportedByDeviceId).slice(0, 64)
    : actorDeviceId;
  const now = new Date().toISOString();

  const { data: existing, error: selErr } = await supabase
    .from("mochi_friend_actions")
    .select("id, count")
    .eq("pair_code", pairCode)
    .eq("actor_name", actorName)
    .eq("action", action)
    .maybeSingle();
  if (selErr) {
    console.warn("supabase friend action select:", selErr.message);
    return { ok: false, error: selErr.message };
  }

  if (existing?.id) {
    const patch = {
      count: (existing.count || 0) + 1,
      last_at: now,
      peer_name: peerName,
    };
    if (actorDeviceId) patch.actor_device_id = actorDeviceId;
    if (peerDeviceId) patch.peer_device_id = peerDeviceId;
    if (reportedBy) patch.reported_by_device_id = reportedBy;
    const { error } = await supabase
      .from("mochi_friend_actions")
      .update(patch)
      .eq("id", existing.id);
    if (error) {
      console.warn("supabase friend action bump:", error.message);
      return { ok: false, error: error.message };
    }
    return { ok: true, count: patch.count };
  }

  const { error } = await supabase.from("mochi_friend_actions").insert({
    pair_code: pairCode,
    actor_device_id: actorDeviceId,
    actor_name: actorName,
    peer_device_id: peerDeviceId,
    peer_name: peerName,
    action,
    count: 1,
    last_at: now,
    reported_by_device_id: reportedBy,
  });
  if (error) {
    // Race on unique — one retry as update.
    if (String(error.code) === "23505" || /duplicate/i.test(error.message || "")) {
      const { data: again } = await supabase
        .from("mochi_friend_actions")
        .select("id, count")
        .eq("pair_code", pairCode)
        .eq("actor_name", actorName)
        .eq("action", action)
        .maybeSingle();
      if (again?.id) {
        const next = (again.count || 0) + 1;
        await supabase
          .from("mochi_friend_actions")
          .update({ count: next, last_at: now, peer_name: peerName })
          .eq("id", again.id);
        return { ok: true, count: next };
      }
    }
    console.warn("supabase friend action insert:", error.message);
    return { ok: false, error: error.message };
  }
  return { ok: true, count: 1 };
}

/**
 * Append a product-analytics row. Always stores owner + timestamps + metrics when provided.
 * Never stores secrets — only CoPet game/UX fields.
 */
export async function logEvent(evt) {
  if (!supabase) return { ok: false, error: "supabase disabled" };
  const ownerId = evt.ownerDeviceId || evt.deviceId || null;
  const ownerName = evt.ownerName || evt.displayName || null;
  let clientTs = null;
  if (evt.clientTs) {
    const d = new Date(evt.clientTs);
    if (!Number.isNaN(d.getTime())) clientTs = d.toISOString();
  }
  const row = {
    created_at: new Date().toISOString(),
    client_ts: clientTs,
    owner_device_id: ownerId ? String(ownerId).slice(0, 64) : null,
    owner_name: ownerName ? String(ownerName).slice(0, 24) : null,
    device_id: ownerId ? String(ownerId).slice(0, 64) : null,
    display_name: ownerName ? String(ownerName).slice(0, 24) : null,
    event: String(evt.event || "unknown").slice(0, 80),
    code: evt.code ? String(evt.code).toUpperCase().replace(/[^A-Z0-9]/g, "").slice(0, 6) : null,
    target_name: evt.targetName ? String(evt.targetName).slice(0, 24) : null,
    species: evt.species ? String(evt.species).slice(0, 12) : null,
    friend_count: Number.isFinite(evt.friendCount) ? Math.max(0, Math.min(500, evt.friendCount)) : null,
    fullness: Number.isFinite(evt.fullness) ? Math.max(0, Math.min(100, evt.fullness)) : null,
    happiness: Number.isFinite(evt.happiness) ? Math.max(0, Math.min(100, evt.happiness)) : null,
    app_version: evt.appVersion ? String(evt.appVersion).slice(0, 24) : null,
    payload: evt.payload && typeof evt.payload === "object" ? evt.payload : {},
  };
  const { error } = await supabase.from("mochi_events").insert(row);
  if (error) {
    console.warn("supabase log event:", error.message);
    return { ok: false, error: error.message };
  }
  return { ok: true };
}
