-- Run once in Supabase SQL editor (safe to re-run).
-- Users, user changelog, binding history, feedback — for CoPet analytics.

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

alter table public.mochi_players add column if not exists owner_name text;
alter table public.mochi_players add column if not exists pad_name text;
alter table public.mochi_players add column if not exists share_code text;
