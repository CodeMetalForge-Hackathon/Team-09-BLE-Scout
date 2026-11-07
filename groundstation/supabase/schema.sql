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
