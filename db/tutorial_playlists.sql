-- Tutorial playlists — reference schema (run in Supabase Dashboard → SQL Editor)
-- This script is idempotent — safe to re-run.
--
-- Lets an admin group tutorial videos into playlists (title + cover image),
-- reorder them, and move videos between playlists — all managed from
-- /admin-tutorials, no code deploy required.

-- ─── TABLES ───────────────────────────────────────────────────────────────────

create table if not exists public.tutorial_playlists (
  id           uuid primary key default gen_random_uuid(),
  title_ar     text not null,
  title_en     text not null,
  cover_url    text,
  sort_order   integer not null default 0,
  created_at   timestamp with time zone default now()
);

create table if not exists public.tutorial_videos (
  id           uuid primary key default gen_random_uuid(),
  playlist_id  uuid references public.tutorial_playlists(id) on delete set null,
  youtube_id   text not null,
  title_ar     text not null,
  title_en     text not null,
  sort_order   integer not null default 0,
  created_at   timestamp with time zone default now()
);

create index if not exists tutorial_videos_playlist_id_idx on public.tutorial_videos(playlist_id);

-- ─── RLS ──────────────────────────────────────────────────────────────────────
-- Read-only for logged-in users (powers the in-app Tutorials page).
-- All writes go through /api/admin/tutorial-playlists + /api/admin/tutorial-videos
-- using the service_role key (bypasses RLS) — no client write policy needed.

alter table public.tutorial_playlists enable row level security;
alter table public.tutorial_videos    enable row level security;

drop policy if exists "tutorial_playlists_select_all" on public.tutorial_playlists;
create policy "tutorial_playlists_select_all" on public.tutorial_playlists
  for select to authenticated using (true);

drop policy if exists "tutorial_videos_select_all" on public.tutorial_videos;
create policy "tutorial_videos_select_all" on public.tutorial_videos
  for select to authenticated using (true);

-- Table-level grants: authenticated needs SELECT only; anon needs nothing.
revoke all on public.tutorial_playlists from anon, authenticated;
revoke all on public.tutorial_videos    from anon, authenticated;
grant  select on public.tutorial_playlists to authenticated;
grant  select on public.tutorial_videos    to authenticated;

-- ─── STORAGE BUCKET ───────────────────────────────────────────────────────────
-- Bucket `tutorial-covers`: public read, admin-only upload. Unlike
-- feedback-images (any authenticated user), cover images are admin-managed
-- content, so INSERT/UPDATE/DELETE are restricted to profiles.role = 'admin'.

insert into storage.buckets (id, name, public)
values ('tutorial-covers', 'tutorial-covers', true)
on conflict (id) do nothing;

drop policy if exists "tutorial_covers_select_public" on storage.objects;
create policy "tutorial_covers_select_public" on storage.objects
  for select using (bucket_id = 'tutorial-covers');

drop policy if exists "tutorial_covers_admin_write" on storage.objects;
create policy "tutorial_covers_admin_write" on storage.objects
  for all to authenticated
  using (
    bucket_id = 'tutorial-covers'
    and (select role from public.profiles where id = (select auth.uid())) = 'admin'
  )
  with check (
    bucket_id = 'tutorial-covers'
    and (select role from public.profiles where id = (select auth.uid())) = 'admin'
  );

-- ─── SEED: migrate the existing hardcoded tutorial videos ────────────────────
-- Moves the 4 videos that used to live in app.html's TUT_VIDEOS array into a
-- single default playlist so nothing disappears when the app switches to
-- reading from these tables. Admin can re-split them from /admin-tutorials.

do $$
declare
  default_playlist_id uuid;
begin
  if not exists (select 1 from public.tutorial_videos) then
    insert into public.tutorial_playlists (title_ar, title_en, sort_order)
    values ('شرح الأداة', 'Tool Explanation', 0)
    returning id into default_playlist_id;

    insert into public.tutorial_videos (playlist_id, youtube_id, title_ar, title_en, sort_order) values
      (default_playlist_id, 'ejKOGYj8_Uo', 'ProfitLens - نظرة عامة على الأداة',      'ProfitLens - Tool Overview',           0),
      (default_playlist_id, '9fiGm833TEU', 'ProfitLens - شرح الأداة (الجزء 2)',      'ProfitLens - Tool Explanation (Part 2)', 1),
      (default_playlist_id, 'KLCCHDjPClY', 'ProfitLens - شرح الأداة (الجزء 3)',      'ProfitLens - Tool Explanation (Part 3)', 2),
      (default_playlist_id, 'Gj27cuD_Pmg', 'ProfitLens - شرح الأداة (الجزء 4)',      'ProfitLens - Tool Explanation (Part 4)', 3);
  end if;
end $$;
