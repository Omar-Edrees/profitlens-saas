-- Run in: Supabase Dashboard → SQL Editor → New Query
-- This script is idempotent — safe to re-run on an existing database.
--
-- Lets the admin panel show how many devices/browsers each user is
-- currently signed in from. auth.sessions has one row per active login
-- session (created on sign-in, removed on sign-out/expiry), but that
-- table lives in the `auth` schema, which PostgREST does not expose to
-- the client SDK. This wraps a count in a SECURITY DEFINER function in
-- `public` so the existing service-role admin API (api/admin/users.js)
-- can read it — same pattern as public.bump_rate_limit in rate_limits.sql.

create or replace function public.admin_session_counts()
returns table(user_id uuid, session_count bigint)
language sql
security definer
set search_path = public
as $$
  select user_id, count(*)::bigint as session_count
  from auth.sessions
  group by user_id;
$$;

-- Not a public RPC — only the server (service_role, which bypasses) invokes it.
revoke execute on function public.admin_session_counts() from public, anon, authenticated;
