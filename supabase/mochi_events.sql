-- Run once in Supabase SQL editor to enable full CoPet event logging.
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
-- Service role (Render) bypasses RLS. No anon policies on purpose.