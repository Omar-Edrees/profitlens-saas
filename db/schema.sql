-- Run in: Supabase Dashboard → SQL Editor → New Query
-- This script is idempotent — safe to re-run on an existing database.

-- ─── TABLES ───────────────────────────────────────────────────────────────────

create table if not exists public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  email      text,
  role       text not null default 'user'  check (role in ('user', 'admin')),
  plan       text not null default 'free'  check (plan in ('free', 'pro', 'enterprise')),
  created_at timestamp with time zone default now()
);

create table if not exists public.user_data (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  data       jsonb not null default '{}',
  updated_at timestamp with time zone default now(),
  unique (user_id)
);

-- ─── TRIGGER: auto-create profile row on sign-up ─────────────────────────────

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email)
  values (new.id, new.email)
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- ─── RLS ─────────────────────────────────────────────────────────────────────

alter table public.profiles  enable row level security;
alter table public.user_data enable row level security;

-- Drop old policies before recreating (prevents "already exists" errors on re-run)
drop policy if exists "users_own_profile_select" on public.profiles;
drop policy if exists "users_own_profile_update" on public.profiles;
drop policy if exists "profiles_select_own"      on public.profiles;
drop policy if exists "profiles_update_own"      on public.profiles;

drop policy if exists "users_own_data_select"    on public.user_data;
drop policy if exists "users_own_data_insert"    on public.user_data;
drop policy if exists "users_own_data_update"    on public.user_data;
drop policy if exists "users_own_data_delete"    on public.user_data;
drop policy if exists "user_data_select_own"     on public.user_data;
drop policy if exists "user_data_insert_own"     on public.user_data;
drop policy if exists "user_data_update_own"     on public.user_data;
drop policy if exists "user_data_delete_own"     on public.user_data;

-- profiles: own row only — WITH CHECK prevents updating id to escape scope
create policy "profiles_select_own" on public.profiles
  for select using (auth.uid() = id);

create policy "profiles_update_own" on public.profiles
  for update using (auth.uid() = id) with check (auth.uid() = id);

-- user_data: own rows only
create policy "user_data_select_own" on public.user_data
  for select using (auth.uid() = user_id);

create policy "user_data_insert_own" on public.user_data
  for insert with check (auth.uid() = user_id);

create policy "user_data_update_own" on public.user_data
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

create policy "user_data_delete_own" on public.user_data
  for delete using (auth.uid() = user_id);

-- ─── COLUMN-LEVEL LOCK: clients can NEVER write role or plan ─────────────────
-- Even with a matching UPDATE policy, anon/authenticated cannot touch these columns.
-- Only service_role (server-side API) or the admin RPC below can change them.

revoke update (role, plan) on public.profiles from anon, authenticated;

-- ─── ADMIN RPC: the only safe path for plan/role changes in application code ──
-- Checks caller is admin, validates inputs, then updates as security definer
-- (bypasses column-level REVOKE because it runs as the function owner, not the user).

create or replace function public.admin_set_plan(target_email text, new_plan text)
returns text language plpgsql security definer set search_path = public as $$
declare
  caller_role text;
  affected    int;
begin
  select role into caller_role from public.profiles where id = auth.uid();
  if caller_role is distinct from 'admin' then
    raise exception 'not authorized';
  end if;
  if new_plan not in ('free', 'pro', 'enterprise') then
    raise exception 'invalid plan: %', new_plan;
  end if;
  update public.profiles set plan = new_plan where email = target_email;
  get diagnostics affected = row_count;
  if affected = 0 then
    raise exception 'user not found: %', target_email;
  end if;
  return target_email || ' -> ' || new_plan;
end;
$$;

-- Any authenticated user can call it, but the function itself enforces admin-only
revoke execute on function public.admin_set_plan(text, text) from public, anon;
grant  execute on function public.admin_set_plan(text, text) to authenticated;

-- ─── BOOTSTRAP (run once after your first sign-up) ───────────────────────────
-- Uncomment, replace the email, then run:
-- update public.profiles set role = 'admin', plan = 'pro'
--   where email = 'your@email.com';
