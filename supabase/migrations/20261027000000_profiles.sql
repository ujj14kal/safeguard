-- Safeguard accounts: one profile row per Supabase Auth user.
-- Run in the Supabase SQL editor of the Safeguard project (or
-- `supabase db push` after `supabase link`). Idempotent.

create table if not exists public.profiles (
  id          uuid primary key references auth.users (id) on delete cascade,
  email       text,
  name        text not null default '',
  phone       text,
  language    text not null default 'en' check (language in ('en', 'hi')),
  consent_at  timestamptz,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- Row level security: a signed-in user can read and edit only their own
-- row. The backend writes with the service-role key, which bypasses RLS;
-- that key never leaves the server.
alter table public.profiles enable row level security;

drop policy if exists "profiles_select_own" on public.profiles;
create policy "profiles_select_own" on public.profiles
  for select using (auth.uid() = id);

drop policy if exists "profiles_update_own" on public.profiles;
create policy "profiles_update_own" on public.profiles
  for update using (auth.uid() = id) with check (auth.uid() = id);

-- No insert/delete policy on purpose: rows are created and removed by the
-- backend (sign-up, account deletion) and by the cascade from auth.users.

create or replace function public.touch_profiles_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;

drop trigger if exists profiles_touch on public.profiles;
create trigger profiles_touch before update on public.profiles
  for each row execute function public.touch_profiles_updated_at();
