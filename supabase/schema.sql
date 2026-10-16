-- CoPet cloud state (run once in Supabase SQL editor)
-- Model: one Mac = one device_id = one player "pad".
-- Bonds are created once (invite → claim). Names update in place when a device renames.

create extension if not exists "pgcrypto";

-- Per-device player profile + friend list (survives app updates / reinstalls)
create table if not exists public.mochi_players (
  device_id text primary key,
  display_name text not null default 'me',
  species text not null default 'dog',
  fullness double precision not null default 80,
  happiness double precision not null default 80,
  friends jsonb not null default '[]'::jsonb,
  active_code text,
  updated_at timestamptz not null default now()
);

-- Invite / bond directory (one code = one pair; host/guest device ids lock the bond)
create table if not exists public.mochi_bonds (
  code text primary key,
  host_name text,
  guest_name text,
  host_device_id text,
  guest_device_id text,
  fullness double precision not null default 80,
  happiness double precision not null default 80,
  created_at timestamptz not null default now(),
  bonded_at timestamptz,
  updated_at timestamptz not null default now()
);

create index if not exists mochi_bonds_host_device_idx on public.mochi_bonds (host_device_id);
create index if not exists mochi_bonds_guest_device_idx on public.mochi_bonds (guest_device_id);

alter table public.mochi_players enable row level security;
alter table public.mochi_bonds enable row level security;
-- Server uses the service role key (bypasses RLS). No anon policies on purpose.
