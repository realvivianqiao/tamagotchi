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

-- Invite / bond directory.
-- personal_hub=true → standing share-code (many can claim; each claim creates a pair row).
create table if not exists public.mochi_bonds (
  code text primary key,
  host_name text,
  guest_name text,
  host_device_id text,
  guest_device_id text,
  personal_hub boolean not null default false,
  fullness double precision not null default 80,
  happiness double precision not null default 80,
  created_at timestamptz not null default now(),
  bonded_at timestamptz,
  updated_at timestamptz not null default now()
);

alter table public.mochi_bonds add column if not exists personal_hub boolean not null default false;

create index if not exists mochi_bonds_host_device_idx on public.mochi_bonds (host_device_id);
create index if not exists mochi_bonds_guest_device_idx on public.mochi_bonds (guest_device_id);

alter table public.mochi_players enable row level security;
alter table public.mochi_bonds enable row level security;
-- Server uses the service role key (bypasses RLS). No anon policies on purpose.

-- Product analytics: every CoPet action with owner + metrics + timestamps.
-- Run this block once in the Supabase SQL editor if the table isn't there yet.
create table if not exists public.mochi_events (
  id bigserial primary key,
  created_at timestamptz not null default now(),
  client_ts timestamptz,
  owner_device_id text,
  owner_name text,
  device_id text,
  display_name text,
  event text not null,
  code text,
  target_name text,
  species text,
  friend_count integer,
  fullness double precision,
  happiness double precision,
  app_version text,
  payload jsonb not null default '{}'::jsonb
);

alter table public.mochi_events add column if not exists client_ts timestamptz;
alter table public.mochi_events add column if not exists owner_device_id text;
alter table public.mochi_events add column if not exists owner_name text;
alter table public.mochi_events add column if not exists fullness double precision;
alter table public.mochi_events add column if not exists happiness double precision;
alter table public.mochi_events add column if not exists app_version text;

create index if not exists mochi_events_created_idx on public.mochi_events (created_at desc);
create index if not exists mochi_events_client_ts_idx on public.mochi_events (client_ts desc);
create index if not exists mochi_events_device_idx on public.mochi_events (device_id);
create index if not exists mochi_events_owner_idx on public.mochi_events (owner_device_id);
create index if not exists mochi_events_event_idx on public.mochi_events (event);

alter table public.mochi_events enable row level security;
