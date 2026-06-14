import { createClient } from '@supabase/supabase-js';

function adminClient() {
  return createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY);
}

// SECURITY: verifies JWT signature via Supabase — no manual decode
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
    const { data: { users: authUsers }, error } = await sb.auth.admin.listUsers();
    if (error) return res.status(500).json({ error: error.message });
    const { data: profiles } = await sb.from('profiles')
      .select('id, role, plan, redeemed_code, redeemed_discount_pct, redeemed_at');
    const profileMap = Object.fromEntries((profiles || []).map(p => [p.id, p]));
    const { data: dataRows } = await sb.from('user_data').select('user_id');
    const hasDataSet = new Set((dataRows || []).map(r => r.user_id));
    const users = authUsers.map(u => {
      const p = profileMap[u.id] || {};
      return {
        id: u.id, email: u.email, created_at: u.created_at,
        last_sign_in_at: u.last_sign_in_at,
        role: p.role || 'user',
        plan: p.plan || 'free',
        has_data: hasDataSet.has(u.id),
        promo_code: p.redeemed_code || null,
        promo_discount: p.redeemed_discount_pct ?? null,
        redeemed_at: p.redeemed_at || null
      };
    });
    return res.status(200).json({ users });
  }

  if (req.method === 'PATCH') {
    const { userId, role } = req.body || {};
    if (!userId || !['user', 'admin'].includes(role)) return res.status(400).json({ error: 'Invalid payload' });
    // update (not upsert) — prevents creating phantom profile rows for arbitrary UUIDs
    const { error } = await sb.from('profiles').update({ role }).eq('id', userId);
    if (error) return res.status(500).json({ error: error.message });
    return res.status(200).json({ ok: true });
  }

  if (req.method === 'DELETE') {
    const { userId } = req.body || {};
    if (!userId) return res.status(400).json({ error: 'userId required' });
    const { error } = await sb.auth.admin.deleteUser(userId);
    if (error) return res.status(500).json({ error: error.message });
    return res.status(200).json({ ok: true });
  }

  return res.status(405).json({ error: 'Method not allowed' });
}
