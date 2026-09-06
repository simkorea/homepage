-- ═══════════════════════════════════════════════════════════════
-- 부정클릭 방지 테이블 백업 (pentaone / tctilpuhknxucrlnhlky)
-- ───────────────────────────────────────────────────────────────
-- ip-fraud-functions-backup.sql 의 세 함수가 의존하는 테이블들이다.
-- 함수만 있고 테이블이 없으면 복원이 안 되므로 같이 받아둔다.
--
-- 2026-09-05 라이브 DB의 pg_class / pg_indexes / pg_policies 에서 추출.
-- 컬럼·인덱스·RLS 정책은 그대로 옮겼고, 읽기 쉽게 형식만 정리했다.
--
-- 2026-09-06 ad_clicks의 익명 INSERT 정책을 라이브 DB에서 삭제하고
-- 이 파일도 맞췄다. 사유와 검증 결과는 ad_clicks 절에 적어두었다.
--
-- 함께 보기:
--   ad-tracking.sql               log_ad_click, keyword_report
--   ip-fraud-functions-backup.sql check_ip_block, check_site_visit,
--                                 suspicious_ips
-- ═══════════════════════════════════════════════════════════════


-- ── 1) ad_clicks ───────────────────────────────────────────────
-- 네이버 광고를 통해 들어온 클릭 한 건이 한 행이다.
-- adguard.js가 광고 파라미터(n_keyword 등)를 감지했을 때만
-- log_ad_click RPC로 쌓인다. suspicious_ips 점수의 원천 데이터.

create table if not exists public.ad_clicks (
  id            uuid primary key default gen_random_uuid(),
  ip_address    text,        -- 서버가 요청 헤더에서 직접 읽는다
  param         text,        -- 광고 파라미터 원문
  user_agent    text,
  is_suspicious boolean default false,
  created_at    timestamptz default now(),
  site          text,        -- ADGUARD_SITE 값 (현장 구분)
  fingerprint   text,
  referrer      text,
  landing_path  text,
  keyword       text,        -- n_keyword : 내가 구매한 키워드
  dwell_ms      integer,     -- 체류 시간. 3초 미만이면 즉시이탈로 본다
  engaged       boolean,     -- 스크롤·클릭 등 반응 여부
  bot_flags     text,        -- 자동화도구 탐지 신호. 있으면 +30점
  search_query  text,        -- n_query : 고객이 실제로 친 검색어
  match_type    text,        -- n_match : 일치 / 키워드확장 / 연관검색 …
  ad_rank       integer      -- n_rank : 광고 노출 순위
);

create index if not exists ad_clicks_created_idx
  on public.ad_clicks using btree (created_at desc);

create index if not exists ad_clicks_ip_created_idx
  on public.ad_clicks using btree (ip_address, created_at desc);

create index if not exists ad_clicks_site_idx
  on public.ad_clicks using btree (site);

create index if not exists ad_clicks_search_query_idx
  on public.ad_clicks using btree (search_query)
  where search_query is not null and search_query <> '';

create index if not exists ad_clicks_match_type_idx
  on public.ad_clicks using btree (match_type)
  where match_type is not null and match_type <> '';

alter table public.ad_clicks enable row level security;

-- 여기엔 INSERT 정책이 없다. 그리고 없는 것이 맞다.
--
-- 2026-09-06 이전에는 아래 정책이 걸려 있었다:
--   create policy "Anyone can insert ad_clicks"
--     on public.ad_clicks for insert to public with check (true);
--
-- anon 키는 모든 현장 사이트 소스에 그대로 노출돼 있으므로, 이 정책은
-- 누구나 REST로 ip_address를 임의로 채운 행을 만들 수 있게 열어둔
-- 구멍이었다. log_ad_click을 SECURITY DEFINER로 만들고 IP를 요청
-- 헤더에서 직접 읽게 한 이유(위조 방지)가 이 정책 하나로 무력화된다.
-- 조작된 행이 쌓이면 suspicious_ips 점수 -> 70점 자동 차단 ->
-- 네이버 광고노출제한에 엉뚱한 IP 등록까지 이어질 수 있었다.
--
-- 지운 뒤 실제로 확인한 것:
--   익명 직접 INSERT  POST /rest/v1/ad_clicks     -> 401 (RLS 위반)
--   익명 RPC 호출     POST /rest/v1/rpc/log_ad_click -> 200, uuid 반환
-- 즉 우회로만 닫히고 정상 기록 경로는 그대로다.
--
-- 클라이언트는 log_ad_click RPC로만 기록한다. 그 함수에는
-- grant execute ... to anon 이 따로 걸려 있어(ad-tracking.sql 참고)
-- RLS INSERT 정책 없이도 동작한다. 되살릴 이유가 없다.

create policy "auth can select ad_clicks"
  on public.ad_clicks for select to authenticated using (true);


-- ── 2) site_visits ─────────────────────────────────────────────
-- 광고 여부와 무관한 일반 방문 기록. 반복접속 차단 판정에 쓴다.
-- check_site_visit이 10분 창 기준으로 세고, 2일 지난 행은
-- 1% 확률로 청소한다.

create table if not exists public.site_visits (
  id         uuid primary key default gen_random_uuid(),
  ip         text,
  site       text,
  created_at timestamptz not null default now()
);

create index if not exists site_visits_site_ip_created_idx
  on public.site_visits using btree (site, ip, created_at desc);

alter table public.site_visits enable row level security;

-- 여기엔 INSERT 정책이 없다. check_site_visit이 SECURITY DEFINER라
-- 함수 소유자 권한으로 넣기 때문에 익명 직접 INSERT를 열 필요가 없다.
-- ad_clicks도 2026-09-06부터 같은 구성이 되었다.
create policy "auth can select site_visits"
  on public.site_visits for select to authenticated using (true);


-- ── 3) ip_blocks ───────────────────────────────────────────────
-- 관리자가 수동으로 차단한 IP. check_ip_block이 여기서 조회한다.
-- until이 지나면 자동으로 풀린다 (행을 지우지 않아도 됨).

create table if not exists public.ip_blocks (
  id         uuid primary key default gen_random_uuid(),
  ip         text not null unique,   -- 같은 IP가 중복 등록되지 않는다
  until      timestamptz not null,   -- 이 시각이 지나면 차단 해제
  reason     text,
  site       text,
  created_at timestamptz not null default now()
);

alter table public.ip_blocks enable row level security;

create policy "auth manages ip_blocks"
  on public.ip_blocks for all to authenticated using (true) with check (true);


-- ── 확인 ───────────────────────────────────────────────────────
select
  (select count(*) from public.ad_clicks)   as ad_clicks_행수,
  (select count(*) from public.site_visits) as site_visits_행수,
  (select count(*) from public.ip_blocks)   as ip_blocks_행수;
