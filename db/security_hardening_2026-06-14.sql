-- ============================================================================
-- ProfitLens — Security hardening migration (2026-06-14)
-- ----------------------------------------------------------------------------
-- Closes a CRITICAL privilege-escalation gap plus least-privilege findings.
-- Non-destructive: changes privileges/policies only, never row data.
-- Idempotent: safe to re-run. Applied to both production and staging.
--
-- Apply in: Supabase Dashboard → SQL Editor → New Query
-- ============================================================================
begin;

-- ── F1 (CRITICAL) — Privilege escalation via direct write to profiles.role/plan ──
-- Any authenticated user could PATCH /rest/v1/profiles?id=eq.<self> with
--   { "role": "admin", "plan": "enterprise" } and self-promote, because
--   anon/authenticated held a TABLE-level UPDATE grant on profiles.
-- A column-level REVOKE (the previous attempt) does NOT override a table grant —
-- the privilege must be revoked at the table level. Clients only ever READ
-- profiles; role/plan changes happen server-side via the service_role key.
revoke all on public.profiles from anon, authenticated;
grant  select on public.profiles to authenticated;

-- Scope policies to the authenticated role and drop the now-unused client UPDATE policy.
drop policy if exists "profiles_select_own" on public.profiles;
create policy "profiles_select_own" on public.profiles
  for select to authenticated using ((select auth.uid()) = id);
drop policy if exists "profiles_update_own" on public.profiles;

drop policy if exists "user_data_select_own" on public.user_data;
create policy "user_data_select_own" on public.user_data
  for select to authenticated using ((select auth.uid()) = user_id);
drop policy if exists "user_data_insert_own" on public.user_data;
create policy "user_data_insert_own" on public.user_data
  for insert to authenticated with check ((select auth.uid()) = user_id);
drop policy if exists "user_data_update_own" on public.user_data;
create policy "user_data_update_own" on public.user_data
  for update to authenticated using ((select auth.uid()) = user_id)
                              with check ((select auth.uid()) = user_id);
drop policy if exists "user_data_delete_own" on public.user_data;
create policy "user_data_delete_own" on public.user_data
  for delete to authenticated using ((select auth.uid()) = user_id);

-- user_data: anon needs no access (gated by RLS anyway; least privilege).
revoke all on public.user_data from anon;

-- ── F2 (LOW) — SECURITY DEFINER trigger fn exposed as a public RPC endpoint ──
-- /rest/v1/rpc/handle_new_user was callable by anon/authenticated. The trigger
-- still fires (it runs as the function owner) after revoking client EXECUTE.
revoke execute on function public.handle_new_user() from public, anon, authenticated;

-- ── F3 (LOW) — promo_codes is service-role only — strip leftover client grants ──
revoke all on public.promo_codes from anon, authenticated;

commit;

-- ── Verification (expect: all writes false, authenticated SELECT true) ──────────
-- select
--   has_column_privilege('authenticated','public.profiles','role','UPDATE') as must_be_false,
--   has_column_privilege('authenticated','public.profiles','plan','UPDATE') as must_be_false,
--   has_table_privilege ('authenticated','public.profiles','SELECT')        as must_be_true,
--   has_table_privilege ('anon','public.profiles','SELECT')                 as must_be_false,
--   has_function_privilege('authenticated','public.handle_new_user()','EXECUTE') as must_be_false;
