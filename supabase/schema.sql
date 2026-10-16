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

-- ---------------------------------------------------------------------------
-- Users: one Mac (device_id) = one user = one permanent share_code for all pets.
-- Pad renames (owner_name / pad_name / species) live here and in the changelog.
-- ---------------------------------------------------------------------------
create table if not exists public.mochi_users (
  device_id text primary key,
  share_code text unique,
  owner_name text not null default 'me',
  pad_name text not null default 'Zuzu',
  species text not null default 'dog',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists mochi_users_share_code_uidx
  on public.mochi_users (share_code) where share_code is not null;

alter table public.mochi_users enable row level security;

-- Field-level history for a user (renames, species swaps, share-code assign, …).
create table if not exists public.mochi_user_changelog (
  id bigserial primary key,
  device_id text not null,
  field text not null,
  old_value text,
  new_value text,
  created_at timestamptz not null default now(),
  payload jsonb not null default '{}'::jsonb
);

create index if not exists mochi_user_changelog_device_idx
  on public.mochi_user_changelog (device_id, created_at desc);

alter table public.mochi_user_changelog enable row level security;

-- Bonding history: latest + historical bindings for analysis (never delete rows).
create table if not exists public.mochi_binding_events (
  id bigserial primary key,
  device_id text not null,
  peer_device_id text,
  pair_code text,
  share_code text,
  event_type text not null,
  peer_name text,
  created_at timestamptz not null default now(),
  payload jsonb not null default '{}'::jsonb
);

create index if not exists mochi_binding_events_device_idx
  on public.mochi_binding_events (device_id, created_at desc);
create index if not exists mochi_binding_events_pair_idx
  on public.mochi_binding_events (pair_code, created_at desc);

alter table public.mochi_binding_events enable row level security;

-- In-app feedback from the menu.
create table if not exists public.mochi_feedback (
  id bigserial primary key,
  device_id text,
  owner_name text,
  body text not null,
  app_version text,
  created_at timestamptz not null default now(),
  payload jsonb not null default '{}'::jsonb
);

create index if not exists mochi_feedback_created_idx
  on public.mochi_feedback (created_at desc);

alter table public.mochi_feedback enable row level security;

-- Enrich player profile so pad renames survive (owner + pad + share code).
alter table public.mochi_players add column if not exists owner_name text;
alter table public.mochi_players add column if not exists pad_name text;
alter table public.mochi_players add column if not exists share_code text;

-- Directed friendship care tallies (e.g. how many times Vivian poked Evars).
-- One row per (bond, actor, action). peer_name is the other person in the bond.
create table if not exists public.mochi_friend_actions (
  id bigserial primary key,
  pair_code text not null,
  actor_device_id text,
  actor_name text not null,
  peer_device_id text,
  peer_name text not null,
  action text not null,
  count integer not null default 0,
  last_at timestamptz not null default now(),
  reported_by_device_id text,
  constraint mochi_friend_actions_uniq unique (pair_code, actor_name, action)
);

create index if not exists mochi_friend_actions_pair_idx
  on public.mochi_friend_actions (pair_code, action);
create index if not exists mochi_friend_actions_actor_idx
  on public.mochi_friend_actions (actor_name, action);
create index if not exists mochi_friend_actions_peer_idx
  on public.mochi_friend_actions (peer_name, action);

alter table public.mochi_friend_actions enable row level security;
