-- ═══════════════════════════════════════════════════════════════
-- 명함에 붙는 현장 콘텐츠 (pentaone / tctilpuhknxucrlnhlky)
-- ───────────────────────────────────────────────────────────────
-- 명함이 연락처만 있는 게 아니라 현장 홍보 이미지·사업개요·방문예약이
-- 붙은 "모바일 홈페이지 축소판"이 된다.
--
-- 현장 콘텐츠는 현장 단위로 한 번만 등록하고 명함이 가져다 쓴다.
-- 상동역 직원이 5명이어도 이미지는 한 번만 넣고, 사업개요가 바뀌면
-- 한 곳만 고치면 5장이 같이 바뀐다.
--
-- 참고한 구조(경쟁사 포토명함):
--   photocard2.iwinv.net/BE10_Z.php?telnum=010-2888-8949
--   BE10_Z = 현장 코드, telnum = 담당자.
--   이미지 경로가 BE10_Z/upload/* 라 현장 공통이다. 같은 모델이다.
--
-- 함께 보기:
--   agent-cards.sql             agent_cards, get_agent_card 최초 정의
--   분양명함\api\_template.js   이 내용을 화면으로 그리는 곳
-- ═══════════════════════════════════════════════════════════════


-- ── 1) card_sites ──────────────────────────────────────────────

create table if not exists public.card_sites (
  slug        text primary key,      -- 현장 코드. 관리자에서만 쓰고 주소에는 안 나온다
  name        text not null,         -- 그란츠 리버파크
  headline    text,                  -- 위대한 변화의 중심
  subhead     text,                  -- 강동 첫 하이엔드 아파트

  hero_url    text,                  -- 대표 이미지. 카카오톡 미리보기(og:image)로도 쓴다

  -- 주신 사업개요 형식을 그대로 담는다:
  --   [{"k":"시공사","v":"DL이앤씨 (대림)"}, {"k":"규모","v":"지하 7층 ~ 지상 42층"}]
  specs       jsonb not null default '[]'::jsonb,

  -- 세로로 이어 붙일 홍보 이미지. 배열 순서가 화면 순서다.
  images      jsonb not null default '[]'::jsonb,

  notice      text,                  -- "담당자 예약제로 운영되오니 방문 전 사전예약 부탁드립니다"
  address     text,                  -- 홍보관 주소
  site_url    text,                  -- 현장 홈페이지가 따로 있으면

  published   boolean not null default false,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),

  constraint card_sites_slug_format check (slug ~ '^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$')
);

create index if not exists card_sites_published_idx
  on public.card_sites using btree (published, name);

drop trigger if exists card_sites_touch on public.card_sites;
create trigger card_sites_touch
  before update on public.card_sites
  for each row execute function public.touch_agent_cards();   -- 같은 트리거 함수를 재사용

alter table public.card_sites enable row level security;

-- agent_cards 와 같은 원칙. 익명 정책을 만들지 않는다.
-- 공개 열람은 get_agent_card() 한 곳으로만 나간다.
create policy "auth manages card_sites"
  on public.card_sites for all to authenticated
  using (true) with check (true);


-- ── 2) agent_cards 를 현장에 연결 ──────────────────────────────
-- 기존 site(현장 이름 자유입력) 컬럼은 지운다. 현장 이름을 두 곳에서
-- 관리하면 반드시 어긋난다. 지금 값이 들어간 행이 없어 잃을 게 없다.

alter table public.agent_cards
  add column if not exists site_slug text
  references public.card_sites(slug) on delete set null;

create index if not exists agent_cards_site_slug_idx
  on public.agent_cards using btree (site_slug);

alter table public.agent_cards drop column if exists site;


-- ── 3) get_agent_card 갱신 ─────────────────────────────────────
-- 카드와 현장을 한 번에 묶어 돌려준다. 명함 페이지가 요청을 두 번
-- 보내지 않게 하려는 것이다.
--
-- 현장이 비공개면 현장 블록만 null 로 빠지고 명함 자체는 살아 있다.
-- 명함은 사람 것이고 현장 홍보는 그 위에 얹힌 것이라, 분양이 끝나
-- 현장을 내려도 담당자 연락처까지 같이 죽을 이유가 없다.

create or replace function public.get_agent_card(p_slug text)
returns jsonb
language sql
security definer
set search_path = public
as $fn$
  select jsonb_build_object(
    'slug',      a.slug,
    'name',      a.name,
    'role',      a.role,
    'org',       a.org,
    'org_en',    a.org_en,
    'tel',       a.tel,
    'mobile',    a.mobile,
    'kakao_url', a.kakao_url,
    'photo_url', a.photo_url,
    'tagline',   a.tagline,
    'about',     a.about,
    'facts',     a.facts,
    'sites',     a.sites,
    'creds',     a.creds,
    'site',      case when s.slug is null then null else jsonb_build_object(
                   'slug',     s.slug,
                   'name',     s.name,
                   'headline', s.headline,
                   'subhead',  s.subhead,
                   'hero_url', s.hero_url,
                   'specs',    s.specs,
                   'images',   s.images,
                   'notice',   s.notice,
                   'address',  s.address,
                   'site_url', s.site_url
                 ) end
  )
  from public.agent_cards a
  left join public.card_sites s
    on s.slug = a.site_slug
   and s.published = true
  where a.slug = lower(btrim(coalesce(p_slug, '')))
    and a.published = true
  limit 1;
$fn$;

revoke all on function public.get_agent_card(text) from public;
grant execute on function public.get_agent_card(text) to anon, authenticated;


-- ── 4) 현장 이미지 보관함 ──────────────────────────────────────
-- 사람 사진(agent-photos)과 버킷을 나눈다. 현장 이미지는 장수가 많고
-- 지우는 기준도 달라서(분양 종료 시 통째로) 섞어두면 정리가 어렵다.

insert into storage.buckets (id, name, public)
values ('site-photos', 'site-photos', true)
on conflict (id) do nothing;

drop policy if exists "public reads site photos" on storage.objects;
create policy "public reads site photos"
  on storage.objects for select to public
  using (bucket_id = 'site-photos');

drop policy if exists "auth writes site photos" on storage.objects;
create policy "auth writes site photos"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'site-photos');

drop policy if exists "auth updates site photos" on storage.objects;
create policy "auth updates site photos"
  on storage.objects for update to authenticated
  using (bucket_id = 'site-photos') with check (bucket_id = 'site-photos');

drop policy if exists "auth deletes site photos" on storage.objects;
create policy "auth deletes site photos"
  on storage.objects for delete to authenticated
  using (bucket_id = 'site-photos');


-- ── 확인 ───────────────────────────────────────────────────────
select
  (select count(*) from public.card_sites)                                    as 현장수,
  (select count(*) from information_schema.columns
     where table_name = 'agent_cards' and column_name = 'site_slug')          as site_slug_생김,
  (select count(*) from information_schema.columns
     where table_name = 'agent_cards' and column_name = 'site')               as site_지워짐_0이면정상,
  (select public.get_agent_card('simjunhyung') ? 'site')                      as 카드에_site_키_있음,
  (select public.get_agent_card('simjunhyung') -> 'site')                     as 현장_미지정이면_null;
