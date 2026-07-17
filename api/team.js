import { createClient } from '@supabase/supabase-js';

const admin = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_ROLE_KEY
);

// Plan → limits. Kept in sync with db/product_limit.sql and db/teams.sql
// (product_limit_for_plan / team_member_limit_for_plan). The DB is the real
// enforcement; these are for the API's own validation and to inform the client.
const PRODUCT_LIMITS = { free: 20, pro: 20, business: 500, enterprise: 1000 };
const MEMBER_LIMITS  = { free: 0,  pro: 0,  business: 5,   enterprise: 10 };

async function getUser(req) {
  const token = (req.headers.authorization || '').replace('Bearer ', '').trim();
  if (!token) return null;
  const { data: { user }, error } = await admin.auth.getUser(token);
  if (error || !user) return null;
  return user;
}

export default async function handler(req, res) {
  if (req.method === 'OPTIONS') return res.status(200).end();

  const user = await getUser(req);
  if (!user) return res.status(401).json({ error: 'Unauthorized' });

  // ── action=me: resolve which workspace the caller works under ──────────────
  // Accepts any pending email invites, then reports the effective owner/role/plan.
  if (req.method === 'GET' && req.query.action === 'me') {
    const { data: ws } = await admin.rpc('resolve_my_workspace', { p_user: user.id });
    const membership = Array.isArray(ws) && ws.length ? ws[0] : null;
    let ownerId = user.id, role = 'owner';
    if (membership) { ownerId = membership.owner_id; role = membership.role; }
    const { data: ownerProfile } = await admin
      .from('profiles').select('plan').eq('id', ownerId).maybeSingle();
    const plan = ownerProfile?.plan || 'free';
    return res.json({
      isMember: !!membership,
      ownerId, role, plan,
      productLimit: PRODUCT_LIMITS[plan] ?? 20,
      memberLimit:  MEMBER_LIMITS[plan]  ?? 0,
    });
  }

  // ── GET: owner's team roster (members + pending invites) ───────────────────
  if (req.method === 'GET') {
    const { data: profile } = await admin
      .from('profiles').select('plan').eq('id', user.id).maybeSingle();
    const plan = profile?.plan || 'free';
    const { data: members } = await admin
      .from('team_members').select('member_id, role, created_at')
      .eq('owner_id', user.id).order('created_at');
    const memberList = [];
    for (const m of (members || [])) {
      const { data: p } = await admin
        .from('profiles').select('email').eq('id', m.member_id).maybeSingle();
      memberList.push({ member_id: m.member_id, role: m.role, email: p?.email || '' });
    }
    const { data: invites } = await admin
      .from('team_invitations').select('email, role').eq('owner_id', user.id).order('created_at');
    return res.json({
      plan,
      memberLimit: MEMBER_LIMITS[plan] ?? 0,
      used: memberList.length + (invites?.length || 0),
      members: memberList,
      invites: invites || [],
    });
  }

  // ── POST: invite a member by email ─────────────────────────────────────────
  if (req.method === 'POST') {
    const { email, role } = req.body || {};
    const em = String(email || '').trim().toLowerCase();
    const rl = role === 'editor' ? 'editor' : 'viewer';
    if (!em || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(em))
      return res.status(400).json({ error: 'إيميل غير صحيح' });

    const { data: profile } = await admin
      .from('profiles').select('plan').eq('id', user.id).maybeSingle();
    const plan = profile?.plan || 'free';
    if ((MEMBER_LIMITS[plan] ?? 0) === 0)
      return res.status(403).json({ error: 'باقتك الحالية مابتسمحش بإضافة أعضاء' });
    if (em === String(user.email || '').toLowerCase())
      return res.status(400).json({ error: 'مينفعش تضيف نفسك' });

    // If a user with this email already exists → add membership directly;
    // otherwise store a pending invitation consumed on their next login.
    const { data: existing } = await admin
      .from('profiles').select('id').ilike('email', em).maybeSingle();

    const table = existing ? 'team_members' : 'team_invitations';
    const row   = existing
      ? { owner_id: user.id, member_id: existing.id, role: rl }
      : { owner_id: user.id, email: em, role: rl };
    const { error } = await admin.from(table).insert(row);
    if (error) {
      if (error.code === '23505') return res.status(400).json({ error: 'العضو ده مضاف/مدعو بالفعل' });
      if (error.code === '23514') return res.status(403).json({ error: 'وصلت للحد الأقصى لأعضاء باقتك' });
      return res.status(500).json({ error: 'فشل إضافة العضو' });
    }
    return res.json({ ok: true, pending: !existing });
  }

  // ── PATCH: change a member's role ──────────────────────────────────────────
  if (req.method === 'PATCH') {
    const { member_id, role } = req.body || {};
    const rl = role === 'editor' ? 'editor' : 'viewer';
    if (!member_id) return res.status(400).json({ error: 'member_id required' });
    const { error } = await admin.from('team_members')
      .update({ role: rl }).eq('owner_id', user.id).eq('member_id', member_id);
    if (error) return res.status(500).json({ error: error.message });
    return res.json({ ok: true });
  }

  // ── DELETE: remove a member, or cancel a pending invite ────────────────────
  if (req.method === 'DELETE') {
    const { member_id, email } = req.body || {};
    if (member_id) {
      const { error } = await admin.from('team_members')
        .delete().eq('owner_id', user.id).eq('member_id', member_id);
      if (error) return res.status(500).json({ error: error.message });
      return res.json({ ok: true });
    }
    if (email) {
      const { error } = await admin.from('team_invitations')
        .delete().eq('owner_id', user.id).ilike('email', String(email).trim().toLowerCase());
      if (error) return res.status(500).json({ error: error.message });
      return res.json({ ok: true });
    }
    return res.status(400).json({ error: 'member_id or email required' });
  }

  return res.status(405).json({ error: 'Method not allowed' });
}
