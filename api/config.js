export default function handler(req, res) {
  if (req.method === 'OPTIONS') return res.status(200).end();
  const supabaseUrl     = process.env.SUPABASE_URL     || '';
  const supabaseAnonKey = process.env.SUPABASE_ANON_KEY || '';
  const authDisabled    = process.env.DISABLE_AUTH === 'true';
  res.status(200).json({ supabaseUrl, supabaseAnonKey, authDisabled });
}
