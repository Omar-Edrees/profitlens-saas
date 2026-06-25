import { createClient } from '@supabase/supabase-js';

const TYPE_AR = { complaint: 'شكوى', suggestion: 'اقتراح', customization: 'طلب كاستمايزيشن' };

async function sendReplyEmail(fbItem, replyMsg) {
  const from = process.env.RESEND_FROM_EMAIL || 'ProfitLens <noreply@profitlens.app>';
  const typeAr = TYPE_AR[fbItem.type] || fbItem.type;
  await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${process.env.RESEND_API_KEY}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      from,
      to: [fbItem.email],
      subject: `رد على ${typeAr}ك — ProfitLens`,
      html: `
        <div dir="rtl" style="font-family:Arial,sans-serif;max-width:560px;margin:0 auto;color:#1a1a2e">
          <div style="background:#5b6af5;padding:24px 32px;border-radius:12px 12px 0 0">
            <h2 style="margin:0;color:#fff;font-size:20px">ProfitLens</h2>
          </div>
          <div style="background:#f8f9ff;padding:28px 32px;border-radius:0 0 12px 12px;border:1px solid #e2e4f0">
            <p style="margin:0 0 16px;font-size:15px">مرحباً،</p>
            <p style="margin:0 0 20px;font-size:14px;color:#444">تم الرد على <strong>${typeAr}ك</strong> المرسلة إلينا.</p>

            <div style="background:#fff;border:1px solid #dde0f0;border-radius:8px;padding:16px 20px;margin-bottom:20px">
              <p style="margin:0 0 6px;font-size:11px;color:#888;text-transform:uppercase;letter-spacing:.05em">رسالتك الأصلية</p>
              <p style="margin:0;font-size:13px;color:#555;white-space:pre-wrap">${escHtml(fbItem.message)}</p>
            </div>

            <div style="background:#eef0ff;border:1px solid #c7cdf7;border-radius:8px;padding:16px 20px;margin-bottom:24px">
              <p style="margin:0 0 6px;font-size:11px;color:#5b6af5;text-transform:uppercase;letter-spacing:.05em;font-weight:700">رد الفريق</p>
              <p style="margin:0;font-size:14px;color:#1a1a2e;white-space:pre-wrap">${escHtml(replyMsg)}</p>
            </div>

            <p style="margin:0;font-size:12px;color:#999">هذا الإيميل تلقائي — يمكنك الرد عليه مباشرة أو التواصل معنا من داخل التطبيق.</p>
          </div>
        </div>`,
    }),
  });
}

function escHtml(s) {
  return String(s ?? '').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
}

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

    // Fetch original feedback for email + type
    const { data: fbItem } = await sb.from('feedback').select('email,type,message').eq('id', feedback_id).single();

    const { error } = await sb.from('feedback_replies').insert({ feedback_id, message: message.trim() });
    if (error) return res.status(500).json({ error: error.message });

    await sb.from('feedback').update({ status: 'reviewed' }).eq('id', feedback_id).eq('status', 'pending');

    // Send email notification (fire-and-forget — don't fail the request if email fails)
    if (fbItem?.email && process.env.RESEND_API_KEY) {
      sendReplyEmail(fbItem, message.trim()).catch(() => {});
    }

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
