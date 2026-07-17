-- Run in: Supabase Dashboard → SQL Editor → New Query
-- This script is idempotent — safe to re-run on an existing database.
--
-- ─── TEAM / MULTI-USER ACCOUNTS ───────────────────────────────────────────────
-- A paid account owner (plan business/enterprise) can invite team members by
-- email. Members log in with their OWN account and see the OWNER's workspace
-- (the owner's public.user_data row). Each member has a role:
--   editor → can read AND edit the owner's data
--   viewer → can read only
--
-- Enforcement lives HERE (Postgres RLS + triggers), not the client — so no
-- crafted request can exceed a plan's member limit or let a viewer write.

-- ─── TABLES ───────────────────────────────────────────────────────────────────
create table if not exists public.team_members (
  owner_id   uuid not null references auth.users(id) on delete cascade,
  member_id  uuid not null references auth.users(id) on delete cascade,
  role       text not null default 'viewer' check (role in ('editor', 'viewer')),
  created_at timestamptz not null default now(),
  primary key (owner_id, member_id)
);
create index if not exists team_members_member_idx on public.team_members(member_id);

-- Pending invitations for emails that don't have an account yet (or haven't
-- accepted). Consumed by resolve_my_workspace() on the member's next app load.
create table if not exists public.team_invitations (
  id         uuid primary key default gen_random_uuid(),
  owner_id   uuid not null references auth.users(id) on delete cascade,
  email      text not null,
  role       text not null default 'viewer' check (role in ('editor', 'viewer')),
  created_at timestamptz not null default now()
);
create unique index if not exists team_invitations_owner_email_idx
  on public.team_invitations(owner_id, lower(email));

alter table public.team_members     enable row level security;
alter table public.team_invitations enable row level security;

-- team_members: readable by the owner and by the member themselves. All writes
-- go through api/team.js with the service_role key (bypasses RLS), so no client
-- write policy — strip default client write grants, keep SELECT.
drop policy if exists "team_members_select" on public.team_members;
create policy "team_members_select" on public.team_members
  for select to authenticated
  using ((select auth.uid()) = owner_id or (select auth.uid()) = member_id);
revoke insert, update, delete on public.team_members from anon, authenticated;

-- team_invitations: service-role only (never expose invite emails to clients).
revoke all on public.team_invitations from anon, authenticated;

-- ─── RLS HELPERS (SECURITY DEFINER) ───────────────────────────────────────────
-- Used inside user_data policies. SECURITY DEFINER so the membership lookup is
-- not itself gated by team_members' RLS (avoids recursive policy evaluation).
create or replace function public.is_team_member(p_owner uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.team_members
    where owner_id = p_owner and member_id = auth.uid()
  );
$$;

create or replace function public.is_team_editor(p_owner uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.team_members
    where owner_id = p_owner and member_id = auth.uid() and role = 'editor'
  );
$$;

revoke execute on function public.is_team_member(uuid) from public, anon;
revoke execute on function public.is_team_editor(uuid) from public, anon;

-- ─── user_data RLS — extend to team members ───────────────────────────────────
-- Replaces the owner-only policies from schema.sql. Members can SELECT the
-- owner's row; only editors can UPDATE it; INSERT/DELETE stay owner-only.
drop policy if exists "user_data_select_own" on public.user_data;
drop policy if exists "user_data_insert_own" on public.user_data;
drop policy if exists "user_data_update_own" on public.user_data;
drop policy if exists "user_data_delete_own" on public.user_data;

create policy "user_data_select_own_or_team" on public.user_data
  for select to authenticated
  using ((select auth.uid()) = user_id or public.is_team_member(user_id));

create policy "user_data_insert_own" on public.user_data
  for insert to authenticated
  with check ((select auth.uid()) = user_id);

create policy "user_data_update_own_or_editor" on public.user_data
  for update to authenticated
  using ((select auth.uid()) = user_id or public.is_team_editor(user_id))
  with check ((select auth.uid()) = user_id or public.is_team_editor(user_id));

create policy "user_data_delete_own" on public.user_data
  for delete to authenticated
  using ((select auth.uid()) = user_id);

-- ─── MEMBER LIMIT PER PLAN ────────────────────────────────────────────────────
create or replace function public.team_member_limit_for_plan(p_plan text)
returns integer
language sql
immutable
as $$
  select case coalesce(p_plan, 'free')
    when 'enterprise' then 10
    when 'business'   then 5
    else 0
  end;
$$;

-- Reject an invite/membership that would push the owner over their plan limit.
-- Counts current members + pending invitations together.
create or replace function public.enforce_team_member_limit()
returns trigger
language plpgsql
as $$
declare
  v_plan  text;
  v_limit integer;
  v_used  integer;
begin
  select plan into v_plan from public.profiles where id = new.owner_id;
  v_limit := public.team_member_limit_for_plan(v_plan);
  select (select count(*) from public.team_members     where owner_id = new.owner_id)
       + (select count(*) from public.team_invitations where owner_id = new.owner_id)
    into v_used;
  if v_used >= v_limit then
    raise exception 'team_member_limit_exceeded: plan % allows max % members',
      coalesce(v_plan, 'free'), v_limit
      using errcode = '23514';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_team_member_limit on public.team_members;
create trigger trg_team_member_limit
  before insert on public.team_members
  for each row execute function public.enforce_team_member_limit();

drop trigger if exists trg_team_invite_limit on public.team_invitations;
create trigger trg_team_invite_limit
  before insert on public.team_invitations
  for each row execute function public.enforce_team_member_limit();

-- ─── WORKSPACE RESOLUTION + INVITE ACCEPTANCE ─────────────────────────────────
-- Called (via service role, passing the caller's id) when the app loads.
-- Converts any pending invitations matching the user's email into memberships,
-- then returns the (owner_id, role) the user should work under — or NULL if the
-- user is not on any team (they use their own workspace).
create or replace function public.resolve_my_workspace(p_user uuid)
returns table(owner_id uuid, role text)
language plpgsql
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  v_email text;
begin
  select email into v_email from auth.users where id = p_user;

  -- Accept pending invites for this email (trigger enforces the member limit;
  -- if an owner is over-limit the insert is skipped and the invite left pending).
  if v_email is not null then
    insert into public.team_members (owner_id, member_id, role)
    select ti.owner_id, p_user, ti.role
    from public.team_invitations ti
    where lower(ti.email) = lower(v_email)
    on conflict (owner_id, member_id) do nothing;

    delete from public.team_invitations ti
    where lower(ti.email) = lower(v_email)
      and exists (
        select 1 from public.team_members tm
        where tm.owner_id = ti.owner_id and tm.member_id = p_user
      );
  end if;

  -- Return the first team this user belongs to (a user is normally on one team).
  return query
    select tm.owner_id, tm.role
    from public.team_members tm
    where tm.member_id = p_user
    order by tm.created_at asc
    limit 1;
end;
$$;

revoke execute on function public.resolve_my_workspace(uuid) from public, anon, authenticated;
