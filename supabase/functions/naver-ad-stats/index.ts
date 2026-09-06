/* ══════════════════════════════════════════════════════════════
   네이버 검색광고 성과 조회 (읽기 전용)
   ──────────────────────────────────────────────────────────────
   admin.html "네이버 광고비" 탭이 쓰는 함수다.
   노출·클릭·광고비처럼 네이버에서만 알 수 있는 숫자를 가져온다.

   ⚠️ 이 함수는 GET만 한다. 네이버 계정을 바꾸는 요청(POST/PUT/
      DELETE)은 아예 보내지 않는다. 등록/해제가 필요하면 그건
      naver-ip-block 함수의 일이다. 둘을 일부러 갈라놨다.
      한쪽이 잘못돼도 다른 쪽 사고로 번지지 않게 하려는 것이다.

   ── 시크릿 (naver-ip-block과 같은 것을 쓴다) ─────────────────
     NAVER_API_KEY       액세스라이선스
     NAVER_SECRET_KEY    비밀키
     NAVER_CUSTOMER_ID   CUSTOMER_ID (숫자)

   ── 왜 이 파일 하나로 다 담았나 ──────────────────────────────
   sign() 함수가 naver-ip-block과 겹친다. _shared로 빼는 게 보통
   맞지만, 이 프로젝트는 Supabase CLI를 링크하지 않고 대시보드에
   코드를 붙여넣어 배포한다. 그 방식에서는 ../\_shared 상대 임포트가
   깨진다. 15줄 중복이 배포 실패보다 싸다고 보고 자체 포함으로 뒀다.
   나중에 CLI 배포로 넘어가면 그때 묶는다.

   ── 호출 방법 (로그인한 관리자 토큰 필요) ────────────────────
     POST /functions/v1/naver-ad-stats
     { "action":"ping" }                      → 인증·시크릿 점검
     { "action":"campaigns" }                 → 캠페인 목록
     { "action":"summary", "days":30 }        → 캠페인별 기간 합계
     { "action":"daily",   "days":30 }        → 전체 일별 추이
     { "action":"raw", "path":"/stats", "query":{...} }  → 진단용 GET

   summary / daily 는 since·until 로 날짜를 직접 줘도 된다.
     { "action":"summary", "since":"2026-08-01", "until":"2026-08-31" }
   ══════════════════════════════════════════════════════════════ */

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const NAVER_BASE = 'https://api.searchad.naver.com';

// 네이버 공식 샘플이 쓰는 기본 필드.
// convCnt·ror(전환) 은 전환추적을 켠 계정에서만 나오므로 기본에서 뺐다.
// 필요하면 호출할 때 fields 로 넘긴다.
const DEFAULT_FIELDS = ['clkCnt', 'impCnt', 'salesAmt', 'ctr', 'cpc', 'avgRnk', 'ccnt'];

// /stats 한 번에 넣을 수 있는 id 개수 상한. 넘치면 나눠 호출한다.
const IDS_PER_CALL = 100;

// 조회 가능한 최대 기간. 실수로 몇 년치를 긁어 타임아웃 나는 것을 막는다.
const MAX_DAYS = 180;

// daily 는 하루에 한 번씩 네이버를 부르므로 기간을 더 좁게 잡는다.
// 62일이면 두 달치라 추이를 보기에 충분하고, 호출 수도 감당된다.
const MAX_DAILY_DAYS = 62;

// daily 를 순차로 돌리면 30일에 30번이라 너무 느리다. 몇 개씩 겹쳐 던진다.
// 너무 올리면 네이버가 429를 줄 수 있어 6으로 뒀다.
const DAILY_CONCURRENCY = 6;

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

/** 네이버 규격: base64( HMAC-SHA256( `${timestamp}.${method}.${path}` ) ) */
async function sign(timestamp: string, method: string, path: string, secret: string) {
  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const mac = await crypto.subtle.sign(
    'HMAC',
    key,
    new TextEncoder().encode(`${timestamp}.${method}.${path}`),
  );
  return btoa(String.fromCharCode(...new Uint8Array(mac)));
}

/**
 * 네이버에 GET 요청 한 번.
 * 서명 대상 경로에는 쿼리스트링을 넣지 않는다 (넣으면 401이 난다).
 */
async function naverGet(path: string, params?: URLSearchParams) {
  const apiKey = Deno.env.get('NAVER_API_KEY');
  const secret = Deno.env.get('NAVER_SECRET_KEY');
  const customer = Deno.env.get('NAVER_CUSTOMER_ID');

  if (!apiKey || !secret || !customer) {
    throw new Error(
      '네이버 API 시크릿(NAVER_API_KEY / NAVER_SECRET_KEY / NAVER_CUSTOMER_ID)이 설정되지 않았습니다. ' +
      'naver-ip-block 함수에 이미 넣어둔 값과 같은 것을 이 함수에도 넣어야 합니다.',
    );
  }

  const ts = Date.now().toString();
  const qs = params?.toString();
  const res = await fetch(NAVER_BASE + path + (qs ? '?' + qs : ''), {
    method: 'GET',
    headers: {
      'Content-Type': 'application/json; charset=UTF-8',
      'X-Timestamp': ts,
      'X-API-KEY': apiKey,
      'X-Customer': customer,
      'X-Signature': await sign(ts, 'GET', path, secret),
    },
  });

  const text = await res.text();
  let parsed: unknown = text;
  try { parsed = JSON.parse(text); } catch { /* 네이버가 평문을 줄 때가 있다 */ }
  return { ok: res.ok, status: res.status, body: parsed };
}

// ── 날짜 유틸 ──────────────────────────────────────────────────
// 광고 성과는 한국시간 기준으로 마감되므로 KST로 오늘을 잡는다.
// UTC로 잡으면 오전 9시 이전에 하루가 밀린다.
function kstToday(): string {
  const now = new Date(Date.now() + 9 * 60 * 60 * 1000);
  return now.toISOString().slice(0, 10);
}

function shiftDays(ymd: string, delta: number): string {
  const d = new Date(ymd + 'T00:00:00Z');
  d.setUTCDate(d.getUTCDate() + delta);
  return d.toISOString().slice(0, 10);
}

const YMD = /^\d{4}-\d{2}-\d{2}$/;

/** days 또는 since/until 을 받아 조회 구간을 정한다. */
function resolveRange(input: { days?: unknown; since?: unknown; until?: unknown }) {
  let until = typeof input.until === 'string' && YMD.test(input.until) ? input.until : kstToday();

  let since: string;
  if (typeof input.since === 'string' && YMD.test(input.since)) {
    since = input.since;
  } else {
    const days = Math.max(1, Math.min(MAX_DAYS, Number(input.days) || 30));
    // days=30 이면 오늘 포함 30일이므로 29일 전부터다.
    since = shiftDays(until, -(days - 1));
  }

  // 거꾸로 넣었으면 바로잡는다
  if (since > until) { const t = since; since = until; until = t; }

  // 너무 긴 구간은 잘라낸다
  const span = Math.round(
    (Date.parse(until + 'T00:00:00Z') - Date.parse(since + 'T00:00:00Z')) / 86400000,
  ) + 1;
  if (span > MAX_DAYS) since = shiftDays(until, -(MAX_DAYS - 1));

  return { since, until };
}

// ── 캠페인 목록 ────────────────────────────────────────────────
type Campaign = {
  nccCampaignId: string;
  name?: string;
  campaignTp?: string;
  status?: string;
  dailyBudget?: number;
  userLock?: boolean;
};

async function fetchCampaigns(): Promise<{ ok: boolean; status: number; list: Campaign[]; body: unknown }> {
  const r = await naverGet('/ncc/campaigns');
  const list = Array.isArray(r.body) ? (r.body as Campaign[]) : [];
  return { ok: r.ok, status: r.status, list, body: r.body };
}

// ── /stats 호출 ────────────────────────────────────────────────
// ids 가 100개를 넘으면 나눠서 부르고 결과를 이어붙인다.
async function fetchStats(
  ids: string[],
  since: string,
  until: string,
  fields: string[],
) {
  const rows: Array<Record<string, unknown>> = [];
  const errors: Array<{ status: number; body: unknown }> = [];

  for (let i = 0; i < ids.length; i += IDS_PER_CALL) {
    const chunk = ids.slice(i, i + IDS_PER_CALL);
    const p = new URLSearchParams();
    // 공식 샘플과 같이 ids 를 반복 파라미터로 넘긴다
    for (const id of chunk) p.append('ids', id);
    // fields·timeRange 는 JSON 문자열이어야 한다. CSV로 넘기면 400이 난다.
    p.set('fields', JSON.stringify(fields));
    p.set('timeRange', JSON.stringify({ since, until }));

    // 한 번 실패했다고 그냥 넘기면 그날 숫자가 0으로 찍혀 조용히 틀린
    // 그래프가 나온다. 일별 조회는 여러 요청을 겹쳐 던지느라 가끔 튕기므로
    // 잠깐 쉬고 한 번 더 물어본다.
    let r = await naverGet('/stats', p);
    if (!r.ok) {
      await new Promise((res) => setTimeout(res, 700));
      r = await naverGet('/stats', p);
    }
    if (!r.ok) { errors.push({ status: r.status, body: r.body }); continue; }

    const data = (r.body as { data?: unknown })?.data;
    if (Array.isArray(data)) rows.push(...(data as Array<Record<string, unknown>>));
  }

  return { rows, errors };
}

function num(v: unknown): number {
  const n = typeof v === 'number' ? v : Number(v);
  return Number.isFinite(n) ? n : 0;
}

/** 노출·클릭·비용은 더할 수 있지만 CTR·CPC는 더하면 안 된다. 합계에서 다시 계산한다. */
function derive(imp: number, clk: number, cost: number) {
  return {
    impCnt: imp,
    clkCnt: clk,
    salesAmt: cost,
    ctr: imp > 0 ? (clk / imp) * 100 : 0,
    cpc: clk > 0 ? cost / clk : 0,
  };
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });

  try {
    // ── 호출자가 로그인한 관리자인지 확인 ──────────────────────
    // 읽기 전용이라도 광고비는 남에게 보여줄 숫자가 아니다.
    const auth = req.headers.get('Authorization') ?? '';
    if (!auth.startsWith('Bearer ')) return json({ error: '인증이 필요합니다.' }, 401);

    const admin = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );
    const { data: userData, error: userErr } = await admin.auth.getUser(auth.replace('Bearer ', ''));
    if (userErr || !userData?.user) return json({ error: '관리자 로그인이 필요합니다.' }, 401);

    const input = await req.json().catch(() => ({}));
    const action = typeof input.action === 'string' ? input.action : 'summary';

    const fields = Array.isArray(input.fields) && input.fields.length
      ? input.fields.filter((f: unknown): f is string => typeof f === 'string')
      : DEFAULT_FIELDS;

    // ── 점검 ──────────────────────────────────────────────────
    // 시크릿이 들어갔는지, 서명이 통하는지만 본다.
    if (action === 'ping') {
      const r = await fetchCampaigns();
      return json({
        action,
        ok: r.ok,
        naverStatus: r.status,
        campaignCount: r.list.length,
        hint: r.ok
          ? '연결 정상입니다.'
          : '네이버가 거부했습니다. 시크릿 3개(API_KEY / SECRET_KEY / CUSTOMER_ID)를 확인하세요.',
        result: r.ok ? undefined : r.body,
      }, r.ok ? 200 : 502);
    }

    // ── 캠페인 목록 ───────────────────────────────────────────
    if (action === 'campaigns') {
      const r = await fetchCampaigns();
      if (!r.ok) return json({ action, ok: false, naverStatus: r.status, result: r.body }, 502);
      return json({
        action,
        ok: true,
        count: r.list.length,
        campaigns: r.list.map((c) => ({
          id: c.nccCampaignId,
          name: c.name ?? '',
          type: c.campaignTp ?? '',
          status: c.status ?? '',
          dailyBudget: c.dailyBudget ?? null,
          // userLock=true 는 광고주가 일시중지해 둔 상태다
          paused: c.userLock === true,
        })),
      });
    }

    // ── 진단용 GET ────────────────────────────────────────────
    // 파라미터 형식을 실제 응답으로 확인할 때만 쓴다. GET 외에는 못 보낸다.
    if (action === 'raw') {
      const path = typeof input.path === 'string' ? input.path : '';
      if (!path.startsWith('/')) return json({ error: 'path는 /로 시작해야 합니다.' }, 400);
      const p = new URLSearchParams();
      const q = (input.query ?? {}) as Record<string, unknown>;
      for (const [k, v] of Object.entries(q)) {
        if (Array.isArray(v)) for (const one of v) p.append(k, String(one));
        else p.set(k, typeof v === 'string' ? v : JSON.stringify(v));
      }
      const r = await naverGet(path, p);
      return json({ action, path, query: p.toString(), naverStatus: r.status, ok: r.ok, result: r.body });
    }

    if (action !== 'summary' && action !== 'daily') {
      return json({ error: 'action은 ping / campaigns / summary / daily / raw 중 하나여야 합니다.' }, 400);
    }

    // ── 여기서부터 summary / daily 공통 ────────────────────────
    const { since, until } = resolveRange(input);

    const camp = await fetchCampaigns();
    if (!camp.ok) return json({ action, ok: false, naverStatus: camp.status, result: camp.body }, 502);

    // 특정 캠페인만 보고 싶으면 campaignIds 로 좁힌다
    const wanted = Array.isArray(input.campaignIds)
      ? new Set(input.campaignIds.filter((v: unknown): v is string => typeof v === 'string'))
      : null;

    const campaigns = wanted ? camp.list.filter((c) => wanted.has(c.nccCampaignId)) : camp.list;
    const ids = campaigns.map((c) => c.nccCampaignId);

    if (!ids.length) {
      return json({
        action, ok: true, since, until, ids: 0,
        note: '조회할 캠페인이 없습니다. 네이버 검색광고에 캠페인이 있는지 확인하세요.',
        rows: [], totals: derive(0, 0, 0),
      });
    }

    const nameById = new Map(campaigns.map((c) => [c.nccCampaignId, c.name ?? c.nccCampaignId]));

    // ── 일별 추이 ─────────────────────────────────────────────
    // /stats 는 일별 분할을 못 한다. timeIncrement 를 넣어봤지만
    // 값이 '1'이면 11001(지원하지 않는 기능), 그 외 값은 조용히 무시되고
    // 기간 합계가 그대로 돌아온다. 그래서 하루씩 따로 물어보는 수밖에 없다.
    //
    // 대신 순차로 돌면 30일에 30번이라 느리므로 몇 개씩 동시에 던진다.
    // timeRange 가 제대로 먹는 것은 확인했다 — 주 단위로 쪼개 더한 값이
    // 30일 합계와 정확히 일치했다.
    if (action === 'daily') {
      const days: string[] = [];
      for (let d = since; d <= until; d = shiftDays(d, 1)) {
        days.push(d);
        if (days.length >= MAX_DAILY_DAYS) break;
      }

      const daily: Array<{ date: string; failed?: boolean } & ReturnType<typeof derive>> = [];
      const errors: Array<{ status: number; body: unknown }> = [];

      for (let i = 0; i < days.length; i += DAILY_CONCURRENCY) {
        const slice = days.slice(i, i + DAILY_CONCURRENCY);
        const settled = await Promise.all(
          slice.map(async (d) => {
            const r = await fetchStats(ids, d, d, fields);
            const t = r.rows.reduce((a, row) => ({
              imp: a.imp + num(row.impCnt),
              clk: a.clk + num(row.clkCnt),
              cost: a.cost + num(row.salesAmt),
            }), { imp: 0, clk: 0, cost: 0 });
            return { date: d, t, errors: r.errors };
          }),
        );
        for (const s of settled) {
          errors.push(...s.errors);
          // 재시도까지 실패한 날은 0으로 찍지 않는다. 0원 쓴 날과
          // 못 물어본 날은 다른 이야기다. failed를 달아 화면에서 구멍으로 보인다.
          daily.push({
            date: s.date,
            ...derive(s.t.imp, s.t.clk, s.t.cost),
            ...(s.errors.length ? { failed: true } : {}),
          });
        }
      }

      daily.sort((a, b) => (a.date < b.date ? -1 : 1));

      const t = daily.reduce((a, d) => ({
        imp: a.imp + d.impCnt, clk: a.clk + d.clkCnt, cost: a.cost + d.salesAmt,
      }), { imp: 0, clk: 0, cost: 0 });

      return json({
        action, ok: errors.length === 0, since, until,
        ids: ids.length,
        daysQueried: days.length,
        // 재시도까지 실패해 값을 모르는 날 수. 0이 아니면 그래프에 구멍이 있다.
        daysFailed: daily.filter((d) => d.failed).length,
        daily,
        totals: derive(t.imp, t.clk, t.cost),
        notice: 'salesAmt(광고비)는 부가세 별도 기준입니다.',
        errors: errors.length ? errors.slice(0, 5) : undefined,
      });
    }

    // ── 캠페인별 기간 합계 ────────────────────────────────────
    const { rows, errors } = await fetchStats(ids, since, until, fields);

    const byId = new Map<string, { imp: number; clk: number; cost: number; rank: number; rankN: number }>();
    for (const r of rows) {
      const id = String((r as Record<string, unknown>).id ?? '');
      if (!id) continue;
      const cur = byId.get(id) ?? { imp: 0, clk: 0, cost: 0, rank: 0, rankN: 0 };
      cur.imp += num(r.impCnt);
      cur.clk += num(r.clkCnt);
      cur.cost += num(r.salesAmt);
      const rk = num(r.avgRnk);
      if (rk > 0) { cur.rank += rk; cur.rankN += 1; }
      byId.set(id, cur);
    }

    const list = ids.map((id) => {
      const v = byId.get(id) ?? { imp: 0, clk: 0, cost: 0, rank: 0, rankN: 0 };
      return {
        id,
        name: nameById.get(id) ?? id,
        ...derive(v.imp, v.clk, v.cost),
        avgRnk: v.rankN > 0 ? v.rank / v.rankN : null,
      };
    }).sort((a, b) => b.salesAmt - a.salesAmt);

    const t = list.reduce((a, c) => ({
      imp: a.imp + c.impCnt, clk: a.clk + c.clkCnt, cost: a.cost + c.salesAmt,
    }), { imp: 0, clk: 0, cost: 0 });

    return json({
      action, ok: errors.length === 0, since, until,
      ids: ids.length,
      rowsReturned: rows.length,
      campaigns: list,
      totals: derive(t.imp, t.clk, t.cost),
      // 네이버 salesAmt 는 부가세 별도 금액이다. 실제 청구액과 10% 차이가 난다.
      notice: 'salesAmt(광고비)는 부가세 별도 기준입니다.',
      errors: errors.length ? errors : undefined,
    });
  } catch (e) {
    return json({ error: String(e instanceof Error ? e.message : e) }, 500);
  }
});
