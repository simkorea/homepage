-- ═══════════════════════════════════════════════════════════════
-- 부정클릭 방지 테이블 백업 (pentaone / tctilpuhknxucrlnhlky)
-- ───────────────────────────────────────────────────────────────
-- ip-fraud-functions-backup.sql 의 세 함수가 의존하는 테이블들이다.
-- 함수만 있고 테이블이 없으면 복원이 안 되므로 같이 받아둔다.
--
-- 2026-09-05 라이브 DB의 pg_class / pg_indexes / pg_policies 에서 추출.
-- 컬럼·인덱스·RLS 정책은 그대로 옮겼고, 읽기 쉽게 형식만 정리했다.
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

-- ⚠️ 이 정책은 익명(anon)에게 ad_clicks 직접 INSERT를 열어준다.
-- anon 키는 모든 사이트 소스에 노출돼 있으므로, 누구든 REST로
-- 임의의 ip_address 값을 넣은 행을 만들 수 있다는 뜻이다.
-- log_ad_click RPC는 IP를 요청 헤더에서 직접 읽어 위조를 막지만,
-- 이 정책이 그 우회로를 열어둔 상태다. 조작된 행이 쌓이면
-- suspicious_ips 점수 → 네이버 광고노출제한 자동 등록까지
-- 영향을 줄 수 있다. 손볼 때 함께 검토할 것.
create policy "Anyone can insert ad_clicks"
  on public.ad_clicks for insert to public with check (true);

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
-- ad_clicks와 달리 우회로가 없는, 더 안전한 구성이다.
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
