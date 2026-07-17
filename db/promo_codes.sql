-- Run in: Supabase Dashboard → SQL Editor → New Query

create table if not exists public.promo_codes (
  id           uuid primary key default gen_random_uuid(),
  code         text unique not null,
  max_uses     integer not null default 1,
  uses_count   integer not null default 0,
  discount_pct integer not null default 100 check (discount_pct between 0 and 100),
  is_active    boolean not null default true,
  created_at   timestamp with time zone default now()
);

-- For databases created before discount_pct existed:
alter table public.promo_codes
  add column if not exists discount_pct integer not null default 100
    check (discount_pct between 0 and 100);

-- Which plan a 100%-code activates (added when tiered pricing shipped).
-- Codes created before this column default to 'pro' (the original behaviour).
alter table public.promo_codes
  add column if not exists plan text not null default 'pro'
    check (plan in ('pro', 'business', 'enterprise'));

alter table public.promo_codes enable row level security;
-- No user-facing policies — service role only (bypasses RLS)
-- Admins manage codes via /admin panel
