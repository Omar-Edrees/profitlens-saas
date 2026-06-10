export default function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  if (req.method === 'OPTIONS') return res.status(200).end();
  const supabaseUrl     = process.env.SUPABASE_URL     || '';
  const supabaseAnonKey = process.env.SUPABASE_ANON_KEY || '';
  res.status(200).json({ supabaseUrl, supabaseAnonKey });
}
