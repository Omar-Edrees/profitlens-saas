import { createClient } from '@supabase/supabase-js';

function adminClient() {
  return createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY);
}

async function verifyAdmin(authHeader) {
  if (!authHeader?.startsWith('Bearer ')) return null;
  const token = authHeader.slice(7);
  const sb = adminClient();
  const { data: { user }, error } = await sb.auth.getUser(token);
  if (error || !user) return null;
  const { data: profile } = await sb.from('profiles').select('role').eq('id', user.id).single();
  return profile?.role === 'admin' ? user.id : null;
}

export default async function handler(req, res) {
  if (req.method === 'OPTIONS') return res.status(200).end();

  const adminId = await verifyAdmin(req.headers.authorization).catch(() => null);
  if (!adminId) return res.status(403).json({ error: 'Forbidden' });

  const sb = adminClient();

  if (req.method === 'GET') {
    const { type, id } = req.query;
    if (id) {
      const { data: item, error: itemErr } = await sb.from('feedback').select('*').eq('id', id).single();
      if (itemErr || !item) return res.status(404).json({ error: 'Not found' });
      const { data: replies } = await sb.from('feedback_replies').select('*').eq('feedback_id', id).order('created_at', { ascending: true });
      return res.status(200).json({ data: { ...item, replies: replies || [] } });
    }
    let query = sb.from('feedback').select('*').order('created_at', { ascending: false });
    if (type) query = query.eq('type', type);
    const { data, error } = await query;
    if (error) return res.status(500).json({ error: error.message });
    return res.status(200).json({ data });
  }

  if (req.method === 'POST') {
    const { feedback_id, message } = req.body || {};
    if (!feedback_id || !message?.trim()) return res.status(400).json({ error: 'Missing fields' });
    const { error } = await sb.from('feedback_replies').insert({ feedback_id, message: message.trim() });
    if (error) return res.status(500).json({ error: error.message });
    await sb.from('feedback').update({ status: 'reviewed' }).eq('id', feedback_id).eq('status', 'pending');
    return res.status(200).json({ ok: true });
  }

  if (req.method === 'PATCH') {
    const { id, status } = req.body || {};
    if (!id || !['pending', 'reviewed', 'resolved'].includes(status))
      return res.status(400).json({ error: 'Invalid input' });
    const { error } = await sb.from('feedback').update({ status }).eq('id', id);
    if (error) return res.status(500).json({ error: error.message });
    return res.status(200).json({ ok: true });
  }

  if (req.method === 'DELETE') {
    const { id } = req.query;
    if (!id) return res.status(400).json({ error: 'Missing id' });
    const { data: row } = await sb.from('feedback').select('image_url').eq('id', id).maybeSingle();
    if (row?.image_url) {
      try {
        const url = new URL(row.image_url);
        const parts = url.pathname.split('/feedback-images/');
        if (parts[1]) await sb.storage.from('feedback-images').remove([parts[1]]);
      } catch (_) {}
    }
    const { error } = await sb.from('feedback').delete().eq('id', id);
    if (error) return res.status(500).json({ error: error.message });
    return res.status(200).json({ ok: true });
  }

  res.status(405).json({ error: 'Method not allowed' });
}
