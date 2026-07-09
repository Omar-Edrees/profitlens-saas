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
    const { data, error } = await admin
      .from('tutorial_videos')
      .select('*')
      .order('sort_order', { ascending: true });
    if (error) return res.status(500).json({ error: error.message });
    return res.json({ videos: data });
  }

  if (req.method === 'POST') {
    const { playlist_id, youtube_id, title_ar, title_en } = req.body || {};
    if (!youtube_id || !title_ar || !title_en)
      return res.status(400).json({ error: 'youtube_id, title_ar and title_en are required' });
    const { data: maxRow } = await admin
      .from('tutorial_videos').select('sort_order')
      .eq('playlist_id', playlist_id || null)
      .order('sort_order', { ascending: false }).limit(1).maybeSingle();
    const nextOrder = (maxRow?.sort_order ?? -1) + 1;
    const { data, error } = await admin
      .from('tutorial_videos')
      .insert({
        playlist_id: playlist_id || null,
        youtube_id: youtube_id.trim(),
        title_ar: title_ar.trim(),
        title_en: title_en.trim(),
        sort_order: nextOrder
      })
      .select().single();
    if (error) return res.status(400).json({ error: error.message });
    return res.json({ video: data });
  }

  if (req.method === 'PATCH') {
    const { id, playlist_id, youtube_id, title_ar, title_en, sort_order } = req.body || {};
    if (!id) return res.status(400).json({ error: 'id is required' });
    const patch = {};
    if (playlist_id !== undefined) patch.playlist_id = playlist_id || null;
    if (youtube_id !== undefined) patch.youtube_id = String(youtube_id).trim();
    if (title_ar !== undefined) patch.title_ar = String(title_ar).trim();
    if (title_en !== undefined) patch.title_en = String(title_en).trim();
    if (sort_order !== undefined) patch.sort_order = Number(sort_order) || 0;
    if (!Object.keys(patch).length) return res.status(400).json({ error: 'Nothing to update' });
    const { data, error } = await admin
      .from('tutorial_videos').update(patch).eq('id', id).select().single();
    if (error) return res.status(400).json({ error: error.message });
    return res.json({ video: data });
  }

  if (req.method === 'DELETE') {
    const { id } = req.body || {};
    if (!id) return res.status(400).json({ error: 'id is required' });
    const { error } = await admin.from('tutorial_videos').delete().eq('id', id);
    if (error) return res.status(500).json({ error: error.message });
    return res.json({ success: true });
  }

  return res.status(405).json({ error: 'Method not allowed' });
}
