-- ═══════════════════════════════════════════════════════
-- 광고 유입 기록 1년 보관 후 자동 파기
-- ──────────────────────────────────────────────────────
-- 개인정보 수집 안내에 "최대 1년 보관 후 파기"로 고지했으므로
-- 실제로 파기되도록 log_ad_click 안에 정리 로직을 넣는다.
-- (site_visits는 check_site_visit에 2일 삭제가 이미 들어가 있다)
--
-- Supabase → SQL Editor 에 붙여넣고 Run 하면 된다.
-- ═══════════════════════════════════════════════════════

create or replace function public.log_ad_click(
  p_site         text,
  p_param        text default null,
  p_keyword      text default null,
  p_referrer     text default null,
  p_landing_path text default null,
  p_fingerprint  text default null,
  p_bot_flags    text default null
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

  -- Supabase 엣지가 세팅하는 헤더에서 실제 접속 IP를 추출
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
     site, keyword, referrer, landing_path, fingerprint, bot_flags)
  values
    (v_ip, left(coalesce(p_param, ''), 500), nullif(v_ua, ''), false,
     left(coalesce(p_site, ''), 80), left(coalesce(p_keyword, ''), 200),
     left(coalesce(p_referrer, ''), 300), left(coalesce(p_landing_path, ''), 300),
     left(coalesce(p_fingerprint, ''), 64), left(coalesce(p_bot_flags, ''), 200))
  returning id into v_id;

  -- 보관기간(1년)이 지난 기록을 파기한다.
  -- 매 호출마다 훑으면 느려지므로 드물게(약 0.5% 확률) 실행한다.
  if random() < 0.005 then
    delete from public.ad_clicks where created_at < now() - interval '1 year';
  end if;

  return v_id;
end
$fn$;

-- 권한은 기존과 동일하게 유지
revoke all on function public.log_ad_click(text, text, text, text, text, text, text) from public;
grant execute on function public.log_ad_click(text, text, text, text, text, text, text) to anon, authenticated;

-- 검증용으로 남아 있던 행 정리
delete from public.ad_clicks where site in ('__POLICYCHECK__', '__TEST__');

-- 확인
select
  (select count(*) from public.ad_clicks)   as ad_clicks_rows,
  (select count(*) from public.site_visits) as site_visits_rows;
