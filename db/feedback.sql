-- Feedback system — reference schema (run in Supabase Dashboard → SQL Editor)
-- Reflects the live schema on both the production and staging projects.
-- This script is idempotent — safe to re-run.

-- ─── TABLES ───────────────────────────────────────────────────────────────────

create table if not exists public.feedback (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid references auth.users(id) on delete set null,
  type       text not null check (type in ('complaint','suggestion','customization')),
  email      text not null,
  message    text not null,
  image_url  text,
  status     text not null default 'pending' check (status in ('pending','reviewed','resolved')),
  created_at timestamp with time zone default now()
);

create table if not exists public.feedback_replies (
  id          uuid primary key default gen_random_uuid(),
  feedback_id uuid not null references public.feedback(id) on delete cascade,
  message     text not null,
  created_at  timestamp with time zone default now()
);

-- ─── RLS ──────────────────────────────────────────────────────────────────────

alter table public.feedback         enable row level security;
alter table public.feedback_replies enable row level security;

-- Authenticated users may submit feedback. The `to authenticated` clause already
-- enforces a logged-in session; with check (true) avoids a null-user_id edge case
-- when the client omits user_id. The client always sends auth.uid() as user_id.
drop policy if exists "feedback_insert_own" on public.feedback;
create policy "feedback_insert_own" on public.feedback
  for insert to authenticated
  with check (true);

-- Users can read back ONLY their own feedback (powers the in-app "My messages" view).
drop policy if exists "feedback_select_own" on public.feedback;
create policy "feedback_select_own" on public.feedback
  for select to authenticated
  using ((select auth.uid()) = user_id);

-- Users can read replies that belong to their own feedback.
drop policy if exists "feedback_replies_select_own" on public.feedback_replies;
create policy "feedback_replies_select_own" on public.feedback_replies
  for select to authenticated
  using (
    feedback_id in (select id from public.feedback where user_id = (select auth.uid()))
  );

-- Admins read/update/delete and insert replies via the service_role key in
-- /api/admin/feedback (service_role bypasses RLS) — no client policy needed for that.

-- Grants: authenticated may insert feedback and read its own rows + replies.
grant insert, select on public.feedback         to authenticated;
grant select         on public.feedback_replies to authenticated;

-- ─── STORAGE BUCKET ───────────────────────────────────────────────────────────
-- Bucket `feedback-images`: public read, 5 MB limit, image mime types.
-- Created via Dashboard → Storage (or insert into storage.buckets). Policies:

-- create policy "feedback_images_insert" on storage.objects
--   for insert to authenticated with check (bucket_id = 'feedback-images');
-- create policy "feedback_images_select" on storage.objects
--   for select using (bucket_id = 'feedback-images');
