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
      .from('promo_codes')
      .select('*')
      .order('created_at', { ascending: false });
    if (error) return res.status(500).json({ error: error.message });
    return res.json({ promos: data });
  }

  if (req.method === 'POST') {
    const { code, max_uses, discount_pct } = req.body || {};
    if (!code) return res.status(400).json({ error: 'code is required' });
    const discount = Math.round(Number(discount_pct));
    if (!Number.isFinite(discount) || discount < 0 || discount > 100)
      return res.status(400).json({ error: 'discount_pct must be between 0 and 100' });
    const { data, error } = await admin
      .from('promo_codes')
      .insert({ code: code.trim().toUpperCase(), max_uses: max_uses || 1, discount_pct: discount })
      .select().single();
    if (error) return res.status(400).json({ error: error.message });
    return res.json({ promo: data });
  }

  if (req.method === 'DELETE') {
    const { id } = req.body || {};
    if (!id) return res.status(400).json({ error: 'id is required' });
    const { error } = await admin.from('promo_codes').delete().eq('id', id);
    if (error) return res.status(500).json({ error: error.message });
    return res.json({ success: true });
  }

  return res.status(405).json({ error: 'Method not allowed' });
}
