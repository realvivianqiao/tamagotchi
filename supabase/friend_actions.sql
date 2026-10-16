-- Directed friendship care tallies (poke/feed/pet/play/nap).
-- Query: how many times A poked B in a bond:
--   select actor_name, peer_name, action, count from mochi_friend_actions
--   where action = 'poke' and pair_code = 'XXXXXX';

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
