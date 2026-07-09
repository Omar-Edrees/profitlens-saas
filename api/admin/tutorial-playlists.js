import { createClient } from '@supabase/supabase-js';

const admin = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_ROLE_KEY
);

async function isAdmin(token) {
  if (!token) return false;
  const { data: { user }, error } = await admin.auth.getUser(token);
  if (error || !user) return false;
  const { data: profile } = await admin
    .from('profiles').select('role').eq('id', user.id).maybeSingle();
  return profile?.role === 'admin';
}

export default async function handler(req, res) {
  if (req.method === 'OPTIONS') return res.status(200).end();

  const token = (req.headers.authorization || '').replace('Bearer ', '').trim();
  if (!(await isAdmin(token))) return res.status(403).json({ error: 'Forbidden' });

  if (req.method === 'GET') {
    const { data: playlists, error } = await admin
      .from('tutorial_playlists')
      .select('*')
      .order('sort_order', { ascending: true });
    if (error) return res.status(500).json({ error: error.message });
    const { data: videos, error: vErr } = await admin
      .from('tutorial_videos')
      .select('id, playlist_id')
      .order('sort_order', { ascending: true });
    if (vErr) return res.status(500).json({ error: vErr.message });
    const counts = {};
    (videos || []).forEach(v => { counts[v.playlist_id] = (counts[v.playlist_id] || 0) + 1; });
    const withCounts = (playlists || []).map(p => ({ ...p, video_count: counts[p.id] || 0 }));
    return res.json({ playlists: withCounts, unassigned_count: (videos || []).filter(v => !v.playlist_id).length });
  }

  if (req.method === 'POST') {
    const { title_ar, title_en, cover_url } = req.body || {};
    if (!title_ar || !title_en) return res.status(400).json({ error: 'title_ar and title_en are required' });
    const { data: maxRow } = await admin
      .from('tutorial_playlists').select('sort_order').order('sort_order', { ascending: false }).limit(1).maybeSingle();
    const nextOrder = (maxRow?.sort_order ?? -1) + 1;
    const { data, error } = await admin
      .from('tutorial_playlists')
      .insert({ title_ar: title_ar.trim(), title_en: title_en.trim(), cover_url: cover_url || null, sort_order: nextOrder })
      .select().single();
    if (error) return res.status(400).json({ error: error.message });
    return res.json({ playlist: data });
  }

  if (req.method === 'PATCH') {
    const { id, title_ar, title_en, cover_url, sort_order } = req.body || {};
    if (!id) return res.status(400).json({ error: 'id is required' });
    const patch = {};
    if (title_ar !== undefined) patch.title_ar = String(title_ar).trim();
    if (title_en !== undefined) patch.title_en = String(title_en).trim();
    if (cover_url !== undefined) patch.cover_url = cover_url || null;
    if (sort_order !== undefined) patch.sort_order = Number(sort_order) || 0;
    if (!Object.keys(patch).length) return res.status(400).json({ error: 'Nothing to update' });
    const { data, error } = await admin
      .from('tutorial_playlists').update(patch).eq('id', id).select().single();
    if (error) return res.status(400).json({ error: error.message });
    return res.json({ playlist: data });
  }

  if (req.method === 'DELETE') {
    const { id } = req.body || {};
    if (!id) return res.status(400).json({ error: 'id is required' });
    // Videos in this playlist fall back to "unassigned" (playlist_id → null via FK on delete set null).
    const { error } = await admin.from('tutorial_playlists').delete().eq('id', id);
    if (error) return res.status(500).json({ error: error.message });
    return res.json({ success: true });
  }

  return res.status(405).json({ error: 'Method not allowed' });
}
