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

  // Rate limit promo attempts to curb code-guessing/abuse (per user and per IP).
  // Atomic DB-backed counter; fails open on limiter infra error so legit redeems never break.
  const ip = String(req.headers['x-forwarded-for'] || '').split(',')[0].trim() || 'unknown';
  const limits = await Promise.all([
    admin.rpc('bump_rate_limit', { p_key: `redeem:user:${user.id}`, p_max: 8,  p_window_seconds: 600 }),
    admin.rpc('bump_rate_limit', { p_key: `redeem:ip:${ip}`,        p_max: 20, p_window_seconds: 600 }),
  ]);
  if (limits.some(r => r.data === false))
    return res.status(429).json({ error: 'Too many attempts. Please try again in a few minutes.' });

  const code = ((req.body || {}).code || '').trim().toUpperCase();
  if (!code) return res.status(400).json({ error: 'No code provided' });

  const { data: profile } = await admin
    .from('profiles').select('plan, redeemed_code').eq('id', user.id).maybeSingle();
  if (profile?.plan && profile.plan !== 'free')
    return res.status(400).json({ error: 'حسابك مفعّل بالفعل' });
  if (profile?.redeemed_code)
    return res.status(400).json({ error: 'إنت مطبّق كوبون بالفعل' });

  const { data: promo } = await admin
    .from('promo_codes')
    .select('id, uses_count, max_uses, discount_pct')
    .eq('code', code)
    .eq('is_active', true)
    .maybeSingle();

  if (!promo)
    return res.status(400).json({ error: 'Invalid or expired promo code' });
  if (promo.uses_count >= promo.max_uses)
    return res.status(400).json({ error: 'This promo code has reached its limit' });

  // Atomic optimistic-lock increment: only the request that reads uses_count=N can update it to N+1.
  // Concurrent requests all read the same N, but only the first UPDATE WHERE uses_count=N succeeds;
  // the rest match 0 rows → rejected. Prevents race-condition over-redemption.
  const { data: claimed } = await admin
    .from('promo_codes')
    .update({ uses_count: promo.uses_count + 1 })
    .eq('id', promo.id)
    .eq('uses_count', promo.uses_count)
    .select('id');

  if (!claimed || claimed.length === 0)
    return res.status(400).json({ error: 'This promo code has reached its limit' });

  // 100% code = free unlock → activate now. Any lower % = discount on the price;
  // the customer pays the discounted amount manually and an admin activates them.
  const discount  = promo.discount_pct;
  const activate  = discount >= 100;

  const updates = {
    redeemed_code: code,
    redeemed_discount_pct: discount,
    redeemed_at: new Date().toISOString(),
  };
  if (activate) updates.plan = 'pro';

  const { error: updateErr } = await admin
    .from('profiles').update(updates).eq('id', user.id);
  if (updateErr) return res.status(500).json({ error: 'Failed to apply promo code' });

  return res.status(200).json({ success: true, activated: activate, discount_pct: discount });
}
