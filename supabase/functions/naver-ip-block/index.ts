/* ══════════════════════════════════════════════════════════════
   네이버 검색광고 광고노출제한 IP 자동 등록
   ──────────────────────────────────────────────────────────────
   의심 IP를 네이버 "광고노출제한 관리"에 등록해 다음 클릭부터
   광고가 노출되지 않게 한다.

   API 키는 이 함수의 시크릿에만 두고 절대 클라이언트로 내보내지
   않는다. index.html 등에 넣으면 누구나 읽을 수 있다.

   설정할 시크릿:
     NAVER_API_KEY       액세스라이선스
     NAVER_SECRET_KEY    비밀키
     NAVER_CUSTOMER_ID   CUSTOMER_ID (숫자)

   호출 방법 (반드시 로그인한 관리자 토큰 필요):
     POST /functions/v1/naver-ip-block
     { "action": "list" }                    → 현재 등록된 제한 IP 조회 (인증 점검용)
     { "action": "preview", "days": 7 }      → 등록 대상 미리보기 (네이버에 아무것도 안 보냄)
     { "action": "apply", "days": 7 }        → 점수 기준(70점 이상)으로 실제 등록
     { "action": "apply", "ips": ["1.2.3.4"] } → 관리자가 고른 IP만 실제 등록
     { "action": "unregister", "ips": ["1.2.3.4"] } → 등록된 제한을 해제
   ══════════════════════════════════════════════════════════════ */

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const NAVER_BASE = 'https://api.searchad.naver.com';

// 네이버 광고노출제한 리소스 경로.
// 최초 1회는 action:"list" 로 호출해 이 경로가 맞는지 확인할 것.
const IP_PATH = '/tool/ip-exclusions';

// 이 점수 이상만 등록한다. 관리자 화면의 기준과 같게 유지한다.
const BLOCK_THRESHOLD = 70;

// 한 번에 등록할 최대 개수. 실수로 대량 등록되는 것을 막는 안전장치.
const MAX_PER_RUN = 50;

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

async function naver(method: 'GET' | 'POST' | 'DELETE', path: string, body?: unknown, query?: string) {
  const apiKey = Deno.env.get('NAVER_API_KEY');
  const secret = Deno.env.get('NAVER_SECRET_KEY');
  const customer = Deno.env.get('NAVER_CUSTOMER_ID');

  if (!apiKey || !secret || !customer) {
    throw new Error('네이버 API 시크릿(NAVER_API_KEY / NAVER_SECRET_KEY / NAVER_CUSTOMER_ID)이 설정되지 않았습니다.');
  }

  const ts = Date.now().toString();
  // 서명 대상은 쿼리스트링을 제외한 경로다.
  const res = await fetch(NAVER_BASE + path + (query ? '?' + query : ''), {
    method,
    headers: {
      'Content-Type': 'application/json; charset=UTF-8',
      'X-Timestamp': ts,
      'X-API-KEY': apiKey,
      'X-Customer': customer,
      'X-Signature': await sign(ts, method, path, secret),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });

  const text = await res.text();
  let parsed: unknown = text;
  try { parsed = JSON.parse(text); } catch { /* 네이버가 평문을 줄 때가 있다 */ }
  return { ok: res.ok, status: res.status, body: parsed };
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });

  try {
    // ── 호출자가 로그인한 관리자인지 확인 ──────────────────────
    // 이 함수는 광고 계정을 바꾸므로 익명 호출을 허용하지 않는다.
    const auth = req.headers.get('Authorization') ?? '';
    if (!auth.startsWith('Bearer ')) return json({ error: '인증이 필요합니다.' }, 401);

    const admin = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );

    const { data: userData, error: userErr } = await admin.auth.getUser(auth.replace('Bearer ', ''));
    if (userErr || !userData?.user) return json({ error: '관리자 로그인이 필요합니다.' }, 401);

    const { action = 'preview', days = 7, ips } = await req.json().catch(() => ({}));

    // ── 인증 점검 / 현재 등록 현황 ────────────────────────────
    if (action === 'list') {
      const r = await naver('GET', IP_PATH);
      return json({ action, naverStatus: r.status, ok: r.ok, result: r.body });
    }

    // ── 등록 해제 ─────────────────────────────────────────────
    // 등록 목록에서 해당 IP의 ipFilterId를 찾아 그것만 지운다.
    // 목록에 없는 IP는 건드리지 않는다.
    if (action === 'unregister') {
      const IPV4_U = /^(\d{1,3}\.){3}\d{1,3}$/;
      const want = (Array.isArray(ips) ? ips : [])
        .filter((v: unknown): v is string => typeof v === 'string' && IPV4_U.test(v.trim()))
        .map((v: string) => v.trim());
      if (!want.length) return json({ error: '해제할 IP가 없습니다.' }, 400);

      const cur = await naver('GET', IP_PATH);
      const list = Array.isArray(cur.body)
        ? (cur.body as Array<{ ipFilterId?: number; filterIp?: string; memo?: string }>)
        : [];
      const hit = list.filter((e) => typeof e.filterIp === 'string' && want.includes(e.filterIp));

      if (!hit.length) {
        return json({ action, requested: want, matched: [], removed: 0, note: '네이버에 등록돼 있지 않습니다.' });
      }

      const ids = hit.map((e) => e.ipFilterId).join(',');
      const r = await naver('DELETE', IP_PATH, undefined, 'ids=' + ids);
      return json({
        action,
        requested: want,
        matched: hit.map((e) => ({ ip: e.filterIp, id: e.ipFilterId, memo: e.memo })),
        removed: r.ok ? hit.length : 0,
        naverStatus: r.status,
        ok: r.ok,
        result: r.body,
      });
    }

    // ── 등록 대상 산출 ────────────────────────────────────────
    const { data: rows, error } = await admin.rpc('suspicious_ips', {
      p_days: days,
      p_min_clicks: 2,
    });
    if (error) return json({ error: error.message }, 500);

    type Row = { ip: string; score: number; clicks: number; reasons: string };
    const all = (rows ?? []) as Row[];

    // ips 가 오면 관리자가 화면에서 직접 고른 것이므로 점수 기준을 적용하지 않는다.
    // 점수는 메모에만 쓰고, 목록에 없는 IP(직접 입력 등)도 그대로 등록한다.
    const IPV4 = /^(\d{1,3}\.){3}\d{1,3}$/;
    let targets: Array<{ ip: string; score: number | null; clicks: number | null; reasons: string | null }>;
    let picked = false;

    if (Array.isArray(ips) && ips.length) {
      const clean = [...new Set(
        ips.filter((v: unknown): v is string => typeof v === 'string' && IPV4.test(v.trim()))
           .map((v: string) => v.trim()),
      )];
      if (!clean.length) return json({ error: '유효한 IP가 없습니다.' }, 400);
      const byIp = new Map(all.map((r) => [r.ip, r]));
      targets = clean.slice(0, MAX_PER_RUN).map((ip) => {
        const r = byIp.get(ip);
        return { ip, score: r?.score ?? null, clicks: r?.clicks ?? null, reasons: r?.reasons ?? null };
      });
      picked = true;
    } else {
      targets = all
        .filter((r) => r.score >= BLOCK_THRESHOLD)
        .slice(0, MAX_PER_RUN)
        .map((r) => ({ ip: r.ip, score: r.score, clicks: r.clicks, reasons: r.reasons }));
    }

    if (action === 'preview') {
      return json({
        action,
        mode: picked ? '관리자 선택' : `${BLOCK_THRESHOLD}점 이상 자동`,
        threshold: picked ? null : BLOCK_THRESHOLD,
        count: targets.length,
        targets,
      });
    }

    if (action !== 'apply') return json({ error: 'action은 list / preview / apply / unregister 중 하나여야 합니다.' }, 400);

    // ── 실제 등록 ─────────────────────────────────────────────
    // 먼저 네이버에 이미 등록된 목록을 읽는다.
    // 다른 목적으로 직접 등록해 둔 IP를 덮어쓰거나 지우지 않기 위해,
    // 추가(POST)만 하고 기존 항목은 절대 건드리지 않는다.
    const existing = await naver('GET', IP_PATH);
    const existingIps: string[] = Array.isArray(existing.body)
      ? (existing.body as Array<{ filterIp?: string }>)
          .map((e) => e.filterIp)
          .filter((v): v is string => typeof v === 'string')
      : [];

    const results = [];
    for (const t of targets) {
      // 이미 등록돼 있으면 네이버를 호출하지 않고 건너뛴다
      if (existingIps.includes(t.ip)) {
        results.push({ ip: t.ip, score: t.score, ok: true, already: true, status: 200 });
        continue;
      }

      // 설명은 25자 제한 (네이버 에러코드 5502)
      const memo = (t.score == null ? '관리자 지정' : `자동차단 ${t.score}점`).slice(0, 25);
      // 필드명은 조회 응답과 동일한 filterIp를 쓴다
      const r = await naver('POST', IP_PATH, { filterIp: t.ip, memo });

      // 5503 = 이미 등록된 IP. 실패가 아니라 이미 처리된 상태다.
      const already = JSON.stringify(r.body).includes('5503');
      results.push({
        ip: t.ip,
        score: t.score,
        ok: r.ok || already,
        already,
        status: r.status,
        detail: r.ok ? undefined : r.body,
      });
    }

    return json({
      action,
      mode: picked ? '관리자 선택' : `${BLOCK_THRESHOLD}점 이상 자동`,
      existingCount: existingIps.length,
      attempted: results.length,
      succeeded: results.filter(r => r.ok).length,
      results,
    });
  } catch (e) {
    return json({ error: String(e instanceof Error ? e.message : e) }, 500);
  }
});
