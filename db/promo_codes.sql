-- Run in: Supabase Dashboard → SQL Editor → New Query

create table if not exists public.promo_codes (
  id         uuid primary key default gen_random_uuid(),
  code       text unique not null,
  max_uses   integer not null default 1,
  uses_count integer not null default 0,
  is_active  boolean not null default true,
  created_at timestamp with time zone default now()
);

alter table public.promo_codes enable row level security;
-- No user-facing policies — service role only (bypasses RLS)
-- Admins manage codes via /admin panel
