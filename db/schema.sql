-- Run in: Supabase Dashboard → SQL Editor → New Query
-- This script is idempotent — safe to re-run on an existing database.

-- ─── TABLES ───────────────────────────────────────────────────────────────────

create table if not exists public.profiles (
  id                    uuid primary key references auth.users(id) on delete cascade,
  email                 text,
  role                  text not null default 'user'  check (role in ('user', 'admin')),
  plan                  text not null default 'free'  check (plan in ('free', 'pro', 'business', 'enterprise')),
  -- promo redemption tracking (written server-side by /api/redeem; shown in the admin panel)
  redeemed_code         text,
  redeemed_discount_pct integer,
  redeemed_at           timestamp with time zone,
  created_at            timestamp with time zone default now()
);

-- For databases created before the redemption columns existed:
alter table public.profiles add column if not exists redeemed_code         text;
alter table public.profiles add column if not exists redeemed_discount_pct integer;
alter table public.profiles add column if not exists redeemed_at           timestamp with time zone;

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

-- profiles: clients may READ their own row only.
-- Clients NEVER write profiles directly — role/plan are changed server-side via the
-- service_role key (api/redeem.js, api/admin/users.js), which bypasses RLS and grants.
-- There is deliberately NO client INSERT/UPDATE/DELETE policy on profiles.
create policy "profiles_select_own" on public.profiles
  for select to authenticated using ((select auth.uid()) = id);

-- user_data: owners get full CRUD on their own rows (USING + WITH CHECK on every write)
create policy "user_data_select_own" on public.user_data
  for select to authenticated using ((select auth.uid()) = user_id);

create policy "user_data_insert_own" on public.user_data
  for insert to authenticated with check ((select auth.uid()) = user_id);

create policy "user_data_update_own" on public.user_data
  for update to authenticated using ((select auth.uid()) = user_id)
                              with check ((select auth.uid()) = user_id);

create policy "user_data_delete_own" on public.user_data
  for delete to authenticated using ((select auth.uid()) = user_id);

-- ─── TABLE-LEVEL PRIVILEGES (CRITICAL — read the warning) ─────────────────────
-- Supabase grants anon/authenticated FULL table privileges by default.
-- ⚠️  A column-level `REVOKE UPDATE (col)` does NOT override a table-level `GRANT UPDATE`.
--     So locking individual columns is useless while the table-wide grant exists —
--     a logged-in user could `PATCH /rest/v1/profiles?id=eq.<self>` and set
--     role='admin'/plan='enterprise'. We must revoke at the TABLE level instead.
--
-- profiles: authenticated needs SELECT only; anon needs nothing.
revoke all on public.profiles from anon, authenticated;
grant  select on public.profiles to authenticated;

-- user_data: authenticated needs full CRUD (gated by RLS above); anon needs nothing.
revoke all on public.user_data from anon;

-- promo_codes: service-role only (see promo_codes.sql) — strip all client grants.
revoke all on public.promo_codes from anon, authenticated;

-- handle_new_user() is a trigger function; it must NOT be exposed as a public RPC.
-- (Revoking EXECUTE does not stop the trigger, which runs as the function owner.)
revoke execute on function public.handle_new_user() from public, anon, authenticated;

-- ─── ADMIN PLAN/ROLE CHANGES ──────────────────────────────────────────────────
-- Application code changes plan/role server-side using the service_role key
-- (api/redeem.js, api/admin/users.js). The service_role bypasses RLS and the
-- table-level revokes above, so no client-callable RPC is required or exposed.

-- ─── BOOTSTRAP (run once after your first sign-up) ───────────────────────────
-- Promote yourself to admin using the SQL editor (runs as a privileged role):
--   update public.profiles set role = 'admin', plan = 'pro'
--     where email = 'your@email.com';
