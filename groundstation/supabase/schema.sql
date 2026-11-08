-- BLE Scout cloud relay. Paste this whole file into Supabase → SQL Editor → Run.
-- Phones add rows with the public (anon / publishable) key; they can't read anything.
-- The ground station reads with the secret (service_role) key, which bypasses these rules.

create table if not exists public.batches (
  id          bigint generated always as identity primary key,
  created_at  timestamptz not null default now(),
  team        text not null check (char_length(team) between 1 and 64),   -- team code, keeps teams apart
  phone_id    text not null check (char_length(phone_id) between 1 and 64),
  name        text check (char_length(name) <= 64),
  kind        text not null default 'batch' check (kind in ('batch', 'ping')),
  payload     jsonb not null                                               -- the phone's batch (see station/server.py)
);

create index if not exists batches_team_id on public.batches (team, id);

alter table public.batches enable row level security;

-- Phones may only insert, and only reasonably sized rows.
drop policy if exists "phones can add batches" on public.batches;
create policy "phones can add batches" on public.batches
  for insert to anon
  with check (octet_length(payload::text) < 2000000);

-- No select/update/delete policies: with row level security on, the public key can't read or change rows.
grant insert on public.batches to anon;

-- ---------------------------------------------------------------------------
-- Signal relay: a phone picks a Bluetooth signal and relays its position to the
-- fleet; other phones forward it hop by hop until a rescuer goes to find it.
-- Phones need to READ these (unlike batches), so the public key may insert and select.
create table if not exists public.relays (
  id            bigint generated always as identity primary key,
  created_at    timestamptz not null default now(),
  team          text not null check (char_length(team) between 1 and 64),
  from_phone    text not null check (char_length(from_phone) between 1 and 64),
  from_name     text check (char_length(from_name) <= 64),
  target_name   text not null check (char_length(target_name) between 1 and 80),
  target_x      double precision not null,
  target_y      double precision not null,
  target_radius double precision,
  hop           int not null default 0,
  chain         jsonb not null default '[]'   -- [{phone_id, name, x, y}] in relay order
);
create index if not exists relays_team_id on public.relays (team, id);
alter table public.relays enable row level security;
drop policy if exists "fleet can add relays" on public.relays;
create policy "fleet can add relays" on public.relays
  for insert to anon with check (octet_length(chain::text) < 20000);
drop policy if exists "fleet can read relays" on public.relays;
create policy "fleet can read relays" on public.relays
  for select to anon using (true);
grant insert, select on public.relays to anon;

-- ---------------------------------------------------------------------------
-- Dispatch: the ground station picks a target and sends one phone (the rescuer) to it.
-- Stored as a relay row with kind = 'dispatch' and to_phone = the rescuer.
alter table public.relays add column if not exists kind text not null default 'relay';
alter table public.relays add column if not exists to_phone text;
alter table public.relays add column if not exists target_names jsonb;
