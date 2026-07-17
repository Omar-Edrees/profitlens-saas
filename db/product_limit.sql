-- Run in: Supabase Dashboard → SQL Editor → New Query
-- This script is idempotent — safe to re-run on an existing database.
--
-- ─── WHY THIS EXISTS ──────────────────────────────────────────────────────────
-- RLS on public.user_data only restricts WHO can write a row (its own owner —
-- see db/schema.sql policies `user_data_insert_own` / `user_data_update_own`).
-- It does NOT restrict WHAT that owner writes. app.html enforces a 20-product
-- cap in the UI, but that is client-side JavaScript running in the user's own
-- browser — trivially bypassed by calling the Supabase client directly with a
-- bigger payload. This trigger makes the cap a real, server-side invariant:
-- Postgres itself rejects any user_data row whose `data.products` array
-- exceeds the caller's plan limit, no matter how the write was made.

-- Per-plan cap. Kept as its own function (not inlined in the trigger) so that
-- when multiple paid tiers ship with different limits, only this one CASE
-- needs to change — the trigger and the client-side check stay untouched.
create or replace function public.product_limit_for_plan(p_plan text)
returns integer
language sql
immutable
as $$
  select case coalesce(p_plan, 'free')
    when 'enterprise' then 20
    when 'pro'        then 20
    else 20
  end;
$$;

create or replace function public.enforce_product_limit()
returns trigger
language plpgsql
as $$
declare
  v_plan  text;
  v_limit integer;
  v_count integer;
begin
  select plan into v_plan from public.profiles where id = new.user_id;
  v_limit := public.product_limit_for_plan(v_plan);
  v_count := case
    when jsonb_typeof(new.data->'products') = 'array'
      then jsonb_array_length(new.data->'products')
    else 0
  end;
  if v_count > v_limit then
    raise exception 'product_limit_exceeded: plan % allows max % products (got %)',
      coalesce(v_plan, 'free'), v_limit, v_count
      using errcode = '23514'; -- check_violation
  end if;
  return new;
end;
$$;

drop trigger if exists trg_enforce_product_limit on public.user_data;
create trigger trg_enforce_product_limit
  before insert or update on public.user_data
  for each row execute function public.enforce_product_limit();

-- Note: enforce_product_limit() is a plain (SECURITY INVOKER) function, not
-- SECURITY DEFINER — it runs with the calling user's own privileges, so its
-- `select ... from public.profiles` is scoped by the existing
-- `profiles_select_own` RLS policy. This is safe because user_data's own
-- policies already guarantee new.user_id = auth.uid(), so the row being read
-- is always the caller's own profile.
