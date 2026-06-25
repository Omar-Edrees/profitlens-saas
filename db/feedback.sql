-- Feedback system — run in Supabase Dashboard → SQL Editor
-- Creates the feedback table + storage bucket (bucket must be created via Supabase Dashboard Storage UI)
-- This script is idempotent — safe to re-run.

-- ─── TABLE ────────────────────────────────────────────────────────────────────

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

-- ─── RLS ──────────────────────────────────────────────────────────────────────

alter table public.feedback enable row level security;

-- Authenticated users can submit their own feedback only; cannot read back.
drop policy if exists "feedback_insert_own" on public.feedback;
create policy "feedback_insert_own" on public.feedback
  for insert to authenticated
  with check ((select auth.uid()) = user_id);

-- Admins read/update/delete via service_role key in /api/admin/feedback — no client policy needed.

-- Strip all client-level grants; service_role bypasses RLS.
revoke all on public.feedback from anon, authenticated;
grant insert on public.feedback to authenticated;

-- ─── STORAGE BUCKET ───────────────────────────────────────────────────────────
-- Create the bucket manually in Supabase Dashboard → Storage → New bucket:
--   Name: feedback-images   Public: true   Max file size: 5 MB   Allowed MIME: image/*
--
-- Then add these storage policies via Dashboard or SQL:

-- Allow authenticated users to upload their own files
-- (bucket RLS policy — run after bucket exists)
/*
create policy "feedback_images_insert" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'feedback-images');

create policy "feedback_images_select_public" on storage.objects
  for select using (bucket_id = 'feedback-images');
*/
