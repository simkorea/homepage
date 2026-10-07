/* ══════════════════════════════════════════════════════════════
   명함 리드 → 담당 직원 개인 이메일 알림
   ──────────────────────────────────────────────────────────────
   consultations에 새 행이 생기면 Supabase Database Webhook이 이 함수를
   부른다(대시보드에서 설정 — card-lead-notify.sql에 기록만 해둠).

   consultations는 명함 말고 다른 현장 상담문의도 같이 쓰는 표라서,
   호출은 오지만 source가 "명함-"로 시작하지 않으면 곧장 건너뛴다.

   담당 직원 mobile이 아니라 email로 보낸다 — 문자는 발송 업체 계정+
   사전 등록 발신번호가 필요해 문턱이 있어서, 이미 다른 현장 사이트들이
   쓰고 있는 Resend로 먼저 간다. agent_cards.email이 비어 있으면 그냥
   건너뛴다(베스트에포트) — admin.html에서는 지금처럼 확인 가능하다.

   설정할 시크릿:
     RESEND_API_KEY   다른 현장 사이트 api/consult.js와 같은 키

   무슨 일이 있어도 200을 돌려준다 — 실패해도 Supabase가 웹훅을
   재시도하며 쌓이게 두지 않는다. 이메일 실패가 리드 저장을 막지도 않는다
   (이 함수는 insert가 끝난 뒤에 불려서, 실패해도 리드는 이미 저장돼 있다).
   ══════════════════════════════════════════════════════════════ */

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

const PREFIX = '명함-';

Deno.serve(async (req) => {
  try {
    const payload = await req.json().catch(() => ({}));
    const record = payload?.record ?? {};

    const source: string = record.source || '';
    if (!source.startsWith(PREFIX)) {
      return json({ skipped: 'not a card lead' });
    }
    const slug = source.slice(PREFIX.length);

    const admin = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );

    // 서버 안쪽이라 공개 RPC(get_agent_card)를 거치지 않고 표를 직접 읽는다.
    const { data: card } = await admin
      .from('agent_cards')
      .select('name, email')
      .eq('slug', slug)
      .maybeSingle();

    // 2026-10-07: Resend 발신이 onboarding@resend.dev 라 계정 주인(simkorea86@gmail.com)
    // 에게만 보낼 수 있다(그 외 403). 직원 개인 메일은 도메인 인증 후에 card.email 로 바꾼다.
    // 그때까지 모든 명함 문의는 대표 메일로 가고, 제목에 담당 직원 이름을 붙인다.
    const to = Deno.env.get('ALERT_EMAIL') || 'simkorea86@gmail.com';
    const agent = card?.name || slug;
    const esc = (s: unknown) => String(s ?? '').replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);

    const isVisit = typeof record.message === 'string' && record.message.startsWith('[방문 희망일]');
    const kind = isVisit ? '방문예약' : '상담문의';

    const apiKey = Deno.env.get('RESEND_API_KEY');
    if (!apiKey) return json({ error: 'RESEND_API_KEY 시크릿이 설정되지 않았습니다.' }, 500);

    const res = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${apiKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        from: 'onboarding@resend.dev',
        to: [to],
        subject: `[분양명함] ${agent} 담당 — ${kind} 도착 — ${record.name || ''}`,
        html: `
          <div style="font-family:'Apple SD Gothic Neo',sans-serif;max-width:520px;margin:0 auto;">
            <p>담당: <strong>${esc(agent)}</strong> (명함 ${esc(slug)})</p>
            <p><strong>${esc(record.name)}</strong> (${esc(record.phone)})</p>
            <p style="white-space:pre-wrap;">${esc(record.message || '(메시지 없음)')}</p>
            <p><a href="https://homepage-iota-dun.vercel.app/admin.html">관리자 페이지에서 보기</a></p>
          </div>`,
      }),
    });
    if (!res.ok) console.error('resend failed', res.status, await res.text());

    return json({ ok: res.ok, kind, slug, mailStatus: res.status });
  } catch (e) {
    // 알림 실패가 웹훅 재시도로 이어지지 않게 200으로 삼킨다.
    return json({ error: String(e instanceof Error ? e.message : e) });
  }
});
