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
    fullness: inv.fullness ?? 80,
    happiness: inv.happiness ?? 80,
    created_at: inv.createdAt ? new Date(inv.createdAt).toISOString() : new Date().toISOString(),
    bonded_at: inv.bondedAt ? new Date(inv.bondedAt).toISOString() : null,
    updated_at: new Date().toISOString(),
  };
  const { error } = await supabase.from("mochi_bonds").upsert(row, { onConflict: "code" });
  if (error) console.warn("supabase save bond:", error.message);
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
