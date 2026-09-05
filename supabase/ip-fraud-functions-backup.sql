-- ═══════════════════════════════════════════════════════════════
-- 부정클릭 방지 함수 백업 (pentaone / tctilpuhknxucrlnhlky)
-- ───────────────────────────────────────────────────────────────
-- 이 세 함수는 지금까지 라이브 DB에만 존재했고 어디에도 백업이
-- 없었다. 실수로 덮어쓰면 되살릴 방법이 없으므로 여기에 받아둔다.
--
-- 2026-09-05 pg_get_functiondef()로 라이브 DB에서 그대로 추출.
--
-- ⚠️ 이 파일은 "함수"만 담고 있다. 함수가 의존하는 테이블
--    (ad_clicks, site_visits, ip_blocks)의 정의는 여기 없다.
--    ad_clicks 관련은 ad-tracking.sql 참고. ip_blocks는 아직
--    어디에도 백업되어 있지 않다.
--
-- 함수를 고칠 일이 생기면 이 파일을 먼저 고치고 DB에 반영해서
-- 파일과 DB가 갈라지지 않게 한다.
-- ═══════════════════════════════════════════════════════════════


-- ── 1) check_ip_block() ────────────────────────────────────────
-- 관리자가 수동으로 차단해 둔 IP인지 확인한다.
-- ip_blocks 테이블에서 until이 아직 안 지난 행을 찾는다.
--
-- 주의: 여기서는 x-forwarded-for만 본다. 아래 check_site_visit은
-- cf-connecting-ip → x-real-ip → x-forwarded-for 순으로 보는데
-- 서로 기준이 다르다. 프록시 구성이 바뀌면 한쪽만 IP를 못 읽는
-- 상황이 생길 수 있으니, 손볼 일이 있으면 둘을 맞추는 것을 검토할 것.

CREATE OR REPLACE FUNCTION public.check_ip_block()
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ declare v_ip text; v_row public.ip_blocks%rowtype; begin v_ip := btrim(split_part(coalesce(current_setting('request.headers', true)::json ->> 'x-forwarded-for', ''), ',', 1)); if v_ip = '' then v_ip := coalesce(host(inet_client_addr()), ''); end if; select * into v_row from public.ip_blocks where ip = v_ip and until > now() limit 1; return json_build_object('ip', v_ip, 'blocked', v_row.id is not null, 'until', v_row.until, 'reason', v_row.reason); end; $function$;


-- ── 2) check_site_visit(p_site) ────────────────────────────────
-- 짧은 시간에 같은 IP가 반복 접속하는지 본다.
--   10분 창 기준 12회부터 warn, 20회부터 blocked.
--   통신사 CGNAT 공유 IP 때문에 임계값을 넉넉하게 잡았다.
--
-- 오차단을 막기 위한 두 가지 장치가 들어있다:
--   - 검색엔진 크롤러(googlebot/yeti/daumoa 등)는 UA로 걸러 항상 ok.
--     SEO 보호. 이건 절대 빼면 안 된다.
--   - IP를 특정할 수 없으면 막지 않고 ok를 준다 (fail-open).
--     진짜 고객을 막는 것보다 봇을 놓치는 쪽이 낫다는 판단.
--
-- site_visits는 2일이 지나면 1% 확률로 청소한다.
-- 매 호출마다 훑으면 느려지므로 드물게 돌린다.

CREATE OR REPLACE FUNCTION public.check_site_visit(p_site text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_headers json;
  v_ip      text;
  v_ua      text;
  v_window  interval := interval '10 minutes';
  v_warn    integer := 12;
  v_block   integer := 20;
  v_count   integer;
begin
  v_headers := nullif(current_setting('request.headers', true), '')::json;

  v_ip := split_part(
            coalesce(
              v_headers ->> 'cf-connecting-ip',
              v_headers ->> 'x-real-ip',
              v_headers ->> 'x-forwarded-for',
              ''
            ), ',', 1);
  v_ip := nullif(trim(v_ip), '');
  v_ua := coalesce(v_headers ->> 'user-agent', '');

  -- 검색엔진 수집봇은 절대 차단하지 않는다 (SEO 보호)
  if v_ua ~* '(googlebot|bingbot|yeti|daumoa|duckduckbot|facebookexternalhit|slackbot|twitterbot|kakaotalk-scrap|yandexbot|petalbot|applebot)' then
    return jsonb_build_object('status', 'ok', 'count', 0);
  end if;

  -- IP를 특정할 수 없으면 막지 않는다 (오차단 방지가 우선)
  if v_ip is null then
    return jsonb_build_object('status', 'ok', 'count', 0);
  end if;

  insert into public.site_visits (ip, site) values (v_ip, left(coalesce(p_site,''), 80));

  select count(*) into v_count
    from public.site_visits
   where site = left(coalesce(p_site,''), 80)
     and ip = v_ip
     and created_at > now() - v_window;

  if random() < 0.01 then
    delete from public.site_visits where created_at < now() - interval '2 days';
  end if;

  return jsonb_build_object(
    'status', case when v_count >= v_block then 'blocked'
                   when v_count >= v_warn  then 'warn'
                   else 'ok' end,
    'count', v_count,
    'window_minutes', 10
  );
end
$function$;


-- ── 3) suspicious_ips(p_days, p_site, p_min_clicks) ────────────
-- 광고 클릭 기록(ad_clicks)을 IP 단위로 묶어 점수를 매긴다.
-- admin.html과 naver-ip-block Edge Function이 이 점수를 받아
-- 70점(BLOCK_THRESHOLD) 이상을 네이버 광고노출제한 등록 후보로 쓴다.
--
-- 점수 배점 (합계 100점 상한):
--   반복 클릭    (클릭수 - 2) × 12점   ← 기본 축. 3회부터 점수가 붙는다
--   즉시이탈     +25점  3초 미만 이탈이 절반 이상
--   무반응       +15점  스크롤·클릭 없음이 절반 이상
--   자동화도구   +30점  bot_flags가 찍힘. 단일 신호 중 가장 무겁다
--   심야집중     +10점  한국시간 0~6시가 절반 이상
--   여러 현장    +15점  현장 2곳 이상에서 같은 IP
--
-- 70점을 넘으려면 예를 들어
--   클릭 7회(60) + 무반응(15) = 75
--   클릭 4회(24) + 즉시이탈(25) + 자동화도구(30) = 79
-- 정도가 되어야 한다. 한두 번 눌러본 실제 고객은 걸리지 않는다.
--
-- reasons 컬럼은 관리자 화면에 그대로 보여주는 사람이 읽는 사유다.

CREATE OR REPLACE FUNCTION public.suspicious_ips(p_days integer DEFAULT 7, p_site text DEFAULT NULL::text, p_min_clicks integer DEFAULT 2)
 RETURNS TABLE(ip text, clicks bigint, site_count bigint, sites text, avg_dwell_ms integer, quick_exits bigint, no_engage bigint, night_hits bigint, bot_hits bigint, first_seen timestamp with time zone, last_seen timestamp with time zone, score integer, reasons text)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with base as (
    select
      c.ip_address as ip,
      c.site,
      c.dwell_ms,
      c.engaged,
      c.bot_flags,
      c.created_at,
      -- 한국시간 기준 자정~오전 6시
      extract(hour from (c.created_at at time zone 'Asia/Seoul')) as kst_hour
    from public.ad_clicks c
    where c.ip_address is not null
      and c.created_at >= now() - make_interval(days => greatest(p_days, 1))
      and (p_site is null or c.site = p_site)
  ),
  agg as (
    select
      ip,
      count(*)                                                      as clicks,
      count(distinct site)                                          as site_count,
      string_agg(distinct site, ', ')                               as sites,
      avg(dwell_ms) filter (where dwell_ms is not null)             as avg_dwell,
      count(*) filter (where dwell_ms is not null and dwell_ms < 3000) as quick_exits,
      count(*) filter (where engaged is false)                      as no_engage,
      count(*) filter (where kst_hour >= 0 and kst_hour < 6)        as night_hits,
      count(*) filter (where bot_flags is not null and bot_flags <> '') as bot_hits,
      min(created_at)                                               as first_seen,
      max(created_at)                                               as last_seen
    from base
    group by ip
  )
  select
    a.ip,
    a.clicks,
    a.site_count,
    a.sites,
    round(a.avg_dwell)::integer as avg_dwell_ms,
    a.quick_exits,
    a.no_engage,
    a.night_hits,
    a.bot_hits,
    a.first_seen,
    a.last_seen,
    least(
      100,
        (greatest(a.clicks - 2, 0) * 12)
      + (case when a.clicks > 0 and a.quick_exits::numeric / a.clicks >= 0.5 then 25 else 0 end)
      + (case when a.clicks > 0 and a.no_engage::numeric  / a.clicks >= 0.5 then 15 else 0 end)
      + (case when a.bot_hits > 0 then 30 else 0 end)
      + (case when a.clicks > 0 and a.night_hits::numeric / a.clicks >= 0.5 then 10 else 0 end)
      + (case when a.site_count >= 2 then 15 else 0 end)
    )::integer as score,
    nullif(concat_ws(', ',
      case when a.clicks >= 3 then a.clicks || '회 반복' end,
      case when a.clicks > 0 and a.quick_exits::numeric / a.clicks >= 0.5 then '즉시이탈' end,
      case when a.clicks > 0 and a.no_engage::numeric  / a.clicks >= 0.5 then '무반응' end,
      case when a.bot_hits > 0 then '자동화도구' end,
      case when a.clicks > 0 and a.night_hits::numeric / a.clicks >= 0.5 then '심야집중' end,
      case when a.site_count >= 2 then a.site_count || '개현장' end
    ), '') as reasons
  from agg a
  where a.clicks >= greatest(p_min_clicks, 1)
  order by score desc, clicks desc;
$function$;


-- ── 확인 ───────────────────────────────────────────────────────
-- 복원 후 세 함수가 다 올라왔는지 확인한다.
select proname
from pg_proc
where proname in ('suspicious_ips','check_ip_block','check_site_visit')
order by proname;
