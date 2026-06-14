-- Run in: Supabase Dashboard → SQL Editor → New Query
-- Rate-limit store + atomic bump function. Service-role only (used by /api/redeem).

create table if not exists public.rate_limits (
  key          text primary key,
  count        int not null default 0,
  window_start timestamptz not null default now()
);

alter table public.rate_limits enable row level security;
-- No user-facing policies — service role only (bypasses RLS). Strip default client grants.
revoke all on public.rate_limits from anon, authenticated;

-- Atomic fixed-window limiter. Returns true if the call is allowed, false if over the limit.
-- Single upsert keeps it race-free under concurrent requests.
create or replace function public.bump_rate_limit(p_key text, p_max int, p_window_seconds int)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare v_count int;
begin
  insert into public.rate_limits (key, count, window_start)
    values (p_key, 1, now())
  on conflict (key) do update set
    count = case when public.rate_limits.window_start < now() - make_interval(secs => p_window_seconds)
                 then 1 else public.rate_limits.count + 1 end,
    window_start = case when public.rate_limits.window_start < now() - make_interval(secs => p_window_seconds)
                 then now() else public.rate_limits.window_start end
  returning count into v_count;
  return v_count <= p_max;
end;
$$;

-- Not a public RPC — only the server (service_role, which bypasses) invokes it.
revoke execute on function public.bump_rate_limit(text,int,int) from public, anon, authenticated;
