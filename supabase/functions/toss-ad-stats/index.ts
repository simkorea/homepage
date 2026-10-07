/* ══════════════════════════════════════════════════════════════
   토스애즈 성과 조회 (읽기 전용)
   ──────────────────────────────────────────────────────────────
   admin.html "토스 광고비" 탭이 쓰는 함수다. naver-ad-stats 와 같은 모양.

   토스 Open API (문서: toss-ads.gitbook.io/toss-ads)
     1) POST https://oauth2.cert.toss.im/token   client_credentials → access_token
     2) POST https://tossads-api.toss.im/v1/reports/query
        - 실패도 HTTP 200 으로 온다. resultType === 'SUCCESS' 를 꼭 본다.
        - 기간 최대 190일, KST, 2025-08-01 부터, 30분 단위 갱신.
        - spend 는 VAT 제외. cpc 는 spend ÷ billable_clicks (토스 정의).

   ── 시크릿 ──────────────────────────────────────────────────
     TOSS_ADS_CLIENT_ID / TOSS_ADS_CLIENT_SECRET   (광고주센터에서 발급)

   ── 호출 (로그인한 관리자 토큰 필요) ────────────────────────
     { "action":"ping" }                → 토큰 발급만 점검
     { "action":"report", "days":30 }   → 일별 + 캠페인별 + 합계
     since/until(YYYY-MM-DD) 로 직접 줘도 된다.
   ══════════════════════════════════════════════════════════════ */

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const TOKEN_URL = 'https://oauth2.cert.toss.im/token';
const QUERY_URL = 'https://tossads-api.toss.im/v1/reports/query';
const METRICS = ['spend', 'impressions', 'clicks', 'billable_clicks', 'leads'];
const MAX_DAYS = 190;

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, 'Content-Type': 'application/json' },
  });
}

// ponytail: 토큰 유효기간이 1년이지만 호출마다 새로 받는다. 관리자 탭에서 가끔 부르는
// 정도라 캐시할 이유가 없다. 호출이 잦아지면 모듈 변수에 expires_in 까지 보관.
async function getToken(): Promise<string> {
  const id = Deno.env.get('TOSS_ADS_CLIENT_ID');
  const secret = Deno.env.get('TOSS_ADS_CLIENT_SECRET');
  if (!id || !secret) throw new Error('시크릿 TOSS_ADS_CLIENT_ID / TOSS_ADS_CLIENT_SECRET 이 없습니다.');

  const res = await fetch(TOKEN_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'Accept': 'application/json; charset=UTF-8' },
    body: new URLSearchParams({
      grant_type: 'client_credentials', client_id: id, client_secret: secret, scope: 'ads:report.read',
    }),
  });
  const body = await res.json().catch(() => null);
  if (!res.ok || !body?.access_token) {
    // 응답 본문에 키가 섞여 나올 일은 없지만, 에러 코드만 넘긴다
    throw new Error(`토스 토큰 발급 실패 (HTTP ${res.status}${body?.error ? ' ' + body.error : ''}). Client ID/Secret 을 확인하세요.`);
  }
  return body.access_token;
}

function kstToday(): string {
  return new Date(Date.now() + 9 * 3600_000).toISOString().slice(0, 10);
}
function shiftDays(ymd: string, delta: number): string {
  const d = new Date(ymd + 'T00:00:00Z');
  d.setUTCDate(d.getUTCDate() + delta);
  return d.toISOString().slice(0, 10);
}
const YMD = /^\d{4}-\d{2}-\d{2}$/;

function resolveRange(input: { days?: unknown; since?: unknown; until?: unknown }) {
  let until = typeof input.until === 'string' && YMD.test(input.until) ? input.until : kstToday();
  let since = typeof input.since === 'string' && YMD.test(input.since)
    ? input.since
    : shiftDays(until, -(Math.max(1, Math.min(MAX_DAYS, Number(input.days) || 30)) - 1));
  if (since > until) [since, until] = [until, since];
  if (since < shiftDays(until, -(MAX_DAYS - 1))) since = shiftDays(until, -(MAX_DAYS - 1));
  return { since, until };
}

type Row = Record<string, string | number>;
const n = (v: unknown) => (Number.isFinite(Number(v)) ? Number(v) : 0);

/** 합계에서 비율을 다시 계산한다. 비율끼리 더하면 틀린다. */
function derive(t: { spend: number; impressions: number; clicks: number; billable_clicks: number; leads: number }) {
  return {
    ...t,
    ctr: t.impressions > 0 ? (t.clicks / t.impressions) * 100 : 0,
    cpc: t.billable_clicks > 0 ? t.spend / t.billable_clicks : 0,
    cost_per_lead: t.leads > 0 ? t.spend / t.leads : 0,
  };
}
const zero = () => ({ spend: 0, impressions: 0, clicks: 0, billable_clicks: 0, leads: 0 });
function add(a: ReturnType<typeof zero>, r: Row) {
  for (const k of METRICS) (a as Record<string, number>)[k] += n(r[k]);
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });

  try {
    const auth = req.headers.get('Authorization') ?? '';
    if (!auth.startsWith('Bearer ')) return json({ error: '인증이 필요합니다.' }, 401);
    const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    const { data: u, error: uErr } = await admin.auth.getUser(auth.replace('Bearer ', ''));
    if (uErr || !u?.user) return json({ error: '관리자 로그인이 필요합니다.' }, 401);

    const input = await req.json().catch(() => ({}));
    const action = input.action === 'ping' ? 'ping' : 'report';

    const token = await getToken();
    if (action === 'ping') return json({ action, ok: true, hint: '토큰 발급 정상입니다.' });

    const { since, until } = resolveRange(input);
    const res = await fetch(QUERY_URL, {
      method: 'POST',
      headers: { 'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        period: { from: since, to: until },
        metrics: METRICS,
        dimensions: ['event_date', 'campaign_id', 'campaign_name'],
        sorts: [{ field: 'event_date', direction: 'asc' }],
      }),
    });
    const body = await res.json().catch(() => null);
    if (!res.ok || body?.resultType !== 'SUCCESS') {
      return json({ ok: false, since, until, tossStatus: res.status, error: body?.error?.reason ?? body?.error ?? '토스 응답 오류' }, 502);
    }
    const rows: Row[] = body.success?.rows ?? [];

    const byDate = new Map<string, ReturnType<typeof zero>>();
    const byCamp = new Map<string, { name: string; t: ReturnType<typeof zero> }>();
    const total = zero();
    for (const r of rows) {
      const d = String(r.event_date);
      if (!byDate.has(d)) byDate.set(d, zero());
      add(byDate.get(d)!, r);
      const id = String(r.campaign_id);
      if (!byCamp.has(id)) byCamp.set(id, { name: String(r.campaign_name || id), t: zero() });
      add(byCamp.get(id)!.t, r);
      add(total, r);
    }

    // 데이터가 없는 날도 0으로 채운다. 토스는 0인 날의 행을 안 준다.
    const daily = [];
    for (let d = since; d <= until; d = shiftDays(d, 1)) daily.push({ date: d, ...derive(byDate.get(d) ?? zero()) });

    return json({
      ok: true, since, until,
      rowCount: body.success?.rowCount ?? rows.length,
      totals: derive(total),
      daily,
      campaigns: [...byCamp.entries()]
        .map(([id, c]) => ({ id, name: c.name, ...derive(c.t) }))
        .sort((a, b) => b.spend - a.spend),
      notice: 'spend(광고비)는 VAT 제외 기준입니다.',
    });
  } catch (e) {
    return json({ error: String(e instanceof Error ? e.message : e) }, 500);
  }
});
