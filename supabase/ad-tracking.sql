-- ═══════════════════════════════════════════════════════════════
-- 네이버 자동 추적 파라미터 수집 + 광고 유입 기록 1년 파기
-- ───────────────────────────────────────────────────────────────
-- Supabase → SQL Editor 에 전체를 붙여넣고 Run 한 번이면 끝난다.
-- 여러 번 실행해도 안전하다.
--
-- 이 파일은 기존 retention.sql을 포함한다. retention.sql은 실행할
-- 필요가 없다.
-- ═══════════════════════════════════════════════════════════════

-- ── 1) 컬럼 추가 ───────────────────────────────────────────────
-- n_keyword(구매한 키워드)는 기존 keyword 컬럼에 계속 들어간다.
-- 아래 세 개는 자동 추적 파라미터를 켜야 값이 들어온다.
alter table public.ad_clicks
  add column if not exists search_query text,   -- n_query : 고객이 실제로 친 검색어
  add column if not exists match_type   text,   -- n_match : 일치 / 키워드확장 / 연관검색 …
  add column if not exists ad_rank      int;    -- n_rank  : 광고 노출 순위

-- 검색어별 집계를 자주 하므로 인덱스를 둔다
create index if not exists ad_clicks_search_query_idx
  on public.ad_clicks (search_query)
  where search_query is not null and search_query <> '';

create index if not exists ad_clicks_match_type_idx
  on public.ad_clicks (match_type)
  where match_type is not null and match_type <> '';


-- ── 2) log_ad_click 교체 ───────────────────────────────────────
-- 기존 7인자 버전을 지우고 10인자 버전으로 바꾼다.
-- 새 인자에 기본값이 있어서, 아직 옛 스크립트가 캐시된 브라우저가
-- 7개만 보내도 그대로 저장된다. (배포 직후 유실 방지)
drop function if exists public.log_ad_click(text, text, text, text, text, text, text);

create or replace function public.log_ad_click(
  p_site         text,
  p_param        text default null,
  p_keyword      text default null,
  p_referrer     text default null,
  p_landing_path text default null,
  p_fingerprint  text default null,
  p_bot_flags    text default null,
  p_search_query text default null,
  p_match_type   text default null,
  p_ad_rank      int  default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_headers json;
  v_ip      text;
  v_ua      text;
  v_id      uuid;
begin
  v_headers := nullif(current_setting('request.headers', true), '')::json;

  -- 접속 IP는 클라이언트가 보낸 값을 믿지 않고 요청 헤더에서 직접 읽는다
  v_ip := split_part(
            coalesce(
              v_headers ->> 'cf-connecting-ip',
              v_headers ->> 'x-real-ip',
              v_headers ->> 'x-forwarded-for',
              ''
            ), ',', 1);
  v_ip := nullif(trim(v_ip), '');

  v_ua := left(coalesce(v_headers ->> 'user-agent', ''), 500);

  insert into public.ad_clicks
    (ip_address, param, user_agent, is_suspicious,
     site, keyword, referrer, landing_path, fingerprint, bot_flags,
     search_query, match_type, ad_rank)
  values
    (v_ip, left(coalesce(p_param, ''), 500), nullif(v_ua, ''), false,
     left(coalesce(p_site, ''), 80), left(coalesce(p_keyword, ''), 200),
     left(coalesce(p_referrer, ''), 300), left(coalesce(p_landing_path, ''), 300),
     left(coalesce(p_fingerprint, ''), 64), left(coalesce(p_bot_flags, ''), 200),
     nullif(left(coalesce(p_search_query, ''), 200), ''),
     nullif(left(coalesce(p_match_type, ''), 20), ''),
     p_ad_rank)
  returning id into v_id;

  -- 보관기간(1년)이 지난 기록을 파기한다.
  -- 개인정보 수집 안내에 고지한 내용이므로 실제로 지워져야 한다.
  -- 매 호출마다 훑으면 느려지므로 드물게(약 0.5% 확률) 실행한다.
  if random() < 0.005 then
    delete from public.ad_clicks where created_at < now() - interval '1 year';
  end if;

  return v_id;
end
$fn$;

revoke all on function public.log_ad_click(text, text, text, text, text, text, text, text, text, int) from public;
grant execute on function public.log_ad_click(text, text, text, text, text, text, text, text, text, int) to anon, authenticated;


-- ── 3) 키워드 리포트 ───────────────────────────────────────────
-- "무슨 키워드로 사서 무슨 검색어로 들어왔는가"를 묶어서 보여준다.
-- 구매 키워드와 실제 검색어가 다르면 키워드 확장으로 들어온 것이고,
-- 그중 체류가 짧고 반응이 없는 조합이 광고비가 새는 지점이다.
create or replace function public.keyword_report(
  p_days int default 30,
  p_site text default null
)
returns table (
  keyword       text,
  search_query  text,
  match_type    text,
  clicks        bigint,
  uniq_ips      bigint,
  avg_rank      numeric,
  quick_exits   bigint,   -- 3초 미만 이탈
  engaged       bigint,   -- 스크롤·클릭 등 반응 있음
  waste_score   int       -- 높을수록 제외 키워드 후보
)
language sql
security definer
set search_path = public
as $fn$
  with base as (
    select
      coalesce(nullif(c.keyword, ''), '(미확인)')      as kw,
      coalesce(nullif(c.search_query, ''), '(미수집)') as q,
      coalesce(nullif(c.match_type, ''), '(미수집)')   as mt,
      c.ip_address, c.ad_rank, c.dwell_ms, c.engaged
    from public.ad_clicks c
    where c.created_at > now() - (p_days || ' days')::interval
      and (p_site is null or c.site = p_site)
  ),
  agg as (
    select
      kw, q, mt,
      count(*)                                              as clicks,
      count(distinct ip_address)                            as uniq_ips,
      round(avg(ad_rank)::numeric, 1)                       as avg_rank,
      count(*) filter (where dwell_ms is not null and dwell_ms < 3000) as quick_exits,
      count(*) filter (where engaged)                       as engaged
    from base
    group by kw, q, mt
  )
  select
    kw, q, mt, clicks, uniq_ips, avg_rank, quick_exits, engaged,
    least(100, (
      -- 확장으로 들어왔는데 구매 키워드와 검색어가 다르다
      case when mt in ('키워드확장','연관검색','유사검색어','스마트블록')
                 and q <> '(미수집)' and q <> kw then 30 else 0 end
      -- 절반 이상이 3초 안에 나갔다
      + case when clicks >= 2 and quick_exits::numeric / clicks >= 0.5 then 35 else 0 end
      -- 반응이 아예 없다
      + case when clicks >= 2 and engaged = 0 then 25 else 0 end
      -- 클릭은 쌓이는데 방문자는 몇 명 안 된다 (같은 사람 반복)
      + case when clicks >= 4 and uniq_ips::numeric / clicks <= 0.5 then 20 else 0 end
    ))::int as waste_score
  from agg
  order by clicks desc, waste_score desc;
$fn$;

-- 관리자만 조회할 수 있다. 검색어는 방문자 정보이므로 익명에게 열지 않는다.
revoke all on function public.keyword_report(int, text) from public, anon;
grant execute on function public.keyword_report(int, text) to authenticated;


-- ── 4) 검증용으로 남아 있던 행 정리 ────────────────────────────
delete from public.ad_clicks where site in ('__POLICYCHECK__', '__TEST__');


-- ── 확인 ───────────────────────────────────────────────────────
select
  (select count(*) from public.ad_clicks)   as ad_clicks_행수,
  (select count(*) from public.site_visits) as site_visits_행수,
  (select count(*) from information_schema.columns
     where table_name = 'ad_clicks'
       and column_name in ('search_query','match_type','ad_rank')) as 새컬럼_3개면정상;
