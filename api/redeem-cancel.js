import { createClient } from '@supabase/supabase-js';

const admin = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_ROLE_KEY
);

export default async function handler(req, res) {
  if (req.method === 'OPTIONS') return res.status(200).end();
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });

  const token = (req.headers.authorization || '').replace('Bearer ', '').trim();
  if (!token) return res.status(401).json({ error: 'Unauthorized' });
  const { data: { user }, error: authErr } = await admin.auth.getUser(token);
  if (authErr || !user) return res.status(401).json({ error: 'Unauthorized' });

  // Same limiter pool as /api/redeem to curb repeated apply/cancel abuse.
  const ip = String(req.headers['x-forwarded-for'] || '').split(',')[0].trim() || 'unknown';
  const limits = await Promise.all([
    admin.rpc('bump_rate_limit', { p_key: `redeem:user:${user.id}`, p_max: 8,  p_window_seconds: 600 }),
    admin.rpc('bump_rate_limit', { p_key: `redeem:ip:${ip}`,        p_max: 20, p_window_seconds: 600 }),
  ]);
  if (limits.some(r => r.data === false))
    return res.status(429).json({ error: 'Too many attempts. Please try again in a few minutes.' });

  const { data: profile } = await admin
    .from('profiles').select('plan, redeemed_code').eq('id', user.id).maybeSingle();

  if (!profile?.redeemed_code)
    return res.status(400).json({ error: 'مفيش كوبون مطبّق على حسابك' });
  if (profile.plan && profile.plan !== 'free')
    return res.status(400).json({ error: 'حسابك مفعّل بالفعل، مينفعش تشيل الكوبون' });

  // Free up the slot on the promo code itself (optimistic-lock decrement,
  // mirrors the increment in /api/redeem). If the code was since deleted/
  // deactivated, this is a no-op — clearing the profile still proceeds.
  const { data: promo } = await admin
    .from('promo_codes')
    .select('id, uses_count')
    .eq('code', profile.redeemed_code)
    .maybeSingle();

  if (promo && promo.uses_count > 0) {
    await admin
      .from('promo_codes')
      .update({ uses_count: promo.uses_count - 1 })
      .eq('id', promo.id)
      .eq('uses_count', promo.uses_count);
  }

  const { error: updateErr } = await admin
    .from('profiles')
    .update({ redeemed_code: null, redeemed_discount_pct: null, redeemed_at: null })
    .eq('id', user.id);
  if (updateErr) return res.status(500).json({ error: 'Failed to remove promo code' });

  return res.status(200).json({ success: true });
}
