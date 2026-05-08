module.exports = async (req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  if (req.method === 'OPTIONS') return res.status(200).end();
  if (req.method !== 'POST') return res.status(405).end();

  const { name, phone, unit_type, message } = req.body || {};
  if (!name || !phone) return res.status(400).json({ error: '이름과 연락처는 필수입니다.' });

  /* ── 1. Supabase 저장 ── */
  const SUPABASE_URL = 'https://tctilpuhknxucrlnhlky.supabase.co';
  const SUPABASE_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRjdGlscHVoa254dWNybG5obGt5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzYxMzE3NjQsImV4cCI6MjA5MTcwNzc2NH0._mS10zf3ayR7nbdFxQJHfZS57_tzOakGm-WkyQB8bxU';

  const sbRes = await fetch(`${SUPABASE_URL}/rest/v1/consultations`, {
    method: 'POST',
    headers: {
      'apikey': SUPABASE_KEY,
      'Authorization': `Bearer ${SUPABASE_KEY}`,
      'Content-Type': 'application/json',
      'Prefer': 'return=minimal'
    },
    body: JSON.stringify({
      name,
      phone,
      unit_type: unit_type || null,
      message: message || null,
      project: 'PH1603 프라이빗 오뜨 갤러리'
    })
  });

  if (!sbRes.ok) {
    const err = await sbRes.text();
    console.error('Supabase error:', err);
    return res.status(500).json({ error: err });
  }

  /* ── 2. Resend 이메일 알림 ── */
  try {
    await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${process.env.RESEND_API_KEY}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({
        from: 'onboarding@resend.dev',
        to: ['wnsgud86@gmail.com'],
        subject: `[PH1603] 새 관심고객 등록 — ${name}`,
        html: `
          <div style="font-family:'Apple SD Gothic Neo',sans-serif;max-width:520px;margin:0 auto;">
            <h2 style="color:#3d2b1f;border-bottom:2px solid #7c5c3a;padding-bottom:10px;margin-bottom:16px;">
              🏢 PH1603 새 관심고객이 등록되었습니다
            </h2>
            <table style="width:100%;border-collapse:collapse;">
              <tr>
                <td style="padding:10px 14px;background:#f9f6f2;font-weight:700;width:30%;border:1px solid #ddd;color:#3d2b1f;">이름</td>
                <td style="padding:10px 14px;border:1px solid #ddd;">${name}</td>
              </tr>
              <tr>
                <td style="padding:10px 14px;background:#f9f6f2;font-weight:700;border:1px solid #ddd;color:#3d2b1f;">연락처</td>
                <td style="padding:10px 14px;border:1px solid #ddd;">
                  <a href="tel:${phone}" style="color:#7c5c3a;font-weight:700;">${phone}</a>
                </td>
              </tr>
              <tr>
                <td style="padding:10px 14px;background:#f9f6f2;font-weight:700;border:1px solid #ddd;color:#3d2b1f;">관심 타입</td>
                <td style="padding:10px 14px;border:1px solid #ddd;">${unit_type || '미선택'}</td>
              </tr>
              <tr>
                <td style="padding:10px 14px;background:#f9f6f2;font-weight:700;border:1px solid #ddd;color:#3d2b1f;">문의 내용</td>
                <td style="padding:10px 14px;border:1px solid #ddd;">${message || '없음'}</td>
              </tr>
            </table>
            <p style="margin-top:20px;color:#aaa;font-size:12px;">
              PH1603 프라이빗 오뜨 갤러리 ·
              <a href="https://ph1603-sigma.vercel.app" style="color:#7c5c3a;">홈페이지 바로가기</a>
            </p>
          </div>
        `
      })
    });
  } catch (_) {}

  return res.status(200).json({ success: true });
};
