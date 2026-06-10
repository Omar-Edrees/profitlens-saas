-- Run in: Supabase Dashboard → SQL Editor → New Query

create table if not exists public.profiles (
  id      uuid primary key references auth.users(id) on delete cascade,
  email   text,
  role    text not null default 'user' check (role in ('user', 'admin')),
  plan    text not null default 'free' check (plan in ('free', 'pro', 'enterprise')),
  created_at timestamp with time zone default now()
);

create table if not exists public.user_data (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  data       jsonb not null default '{}',
  updated_at timestamp with time zone default now(),
  unique (user_id)
);

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

alter table public.profiles  enable row level security;
alter table public.user_data enable row level security;

create policy "users_own_profile_select" on public.profiles for select using (auth.uid() = id);
create policy "users_own_profile_update" on public.profiles for update using (auth.uid() = id);
create policy "users_own_data_select"    on public.user_data for select using (auth.uid() = user_id);
create policy "users_own_data_insert"    on public.user_data for insert with check (auth.uid() = user_id);
create policy "users_own_data_update"    on public.user_data for update using (auth.uid() = user_id);
create policy "users_own_data_delete"    on public.user_data for delete using (auth.uid() = user_id);

-- After your first sign-up, grant yourself admin:
-- update public.profiles set role = 'admin' where email = 'your@email.com';
