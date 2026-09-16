-- ═══════════════════════════════════════════════════════════════
-- 명함별 대표이미지 오버라이드 (pentaone / tctilpuhknxucrlnhlky)
-- ───────────────────────────────────────────────────────────────
-- 지금은 현장 하나(card_sites.hero_url)를 그 현장 직원 전원이 공유한다.
-- 그게 핵심 장점이었지만(이미지 한 번만 넣으면 됨), 참고했던 경쟁사
-- (photocard2.iwinv.net)처럼 사람마다 합성된 개인 배너를 쓰고 싶을 때도
-- 있다. 그래서 카드 쪽에 선택적으로 하나 더 둔다 — 비어 있으면 지금처럼
-- site.hero_url로 폴백한다.
--
-- card_sites.hero_url과 이름이 같지만 헷갈릴 일은 없다: 하나는 카드
-- 최상위(a.hero_url), 하나는 site 하위 객체(site.hero_url)에 있고,
-- _template.js가 card.hero_url || site.hero_url 순서로 고른다.
--
-- 함께 보기:
--   agent-cards.sql   agent_cards, get_agent_card 최초 정의
--   card-sites.sql    site 하위 객체를 붙인 버전
-- ═══════════════════════════════════════════════════════════════

alter table public.agent_cards
  add column if not exists hero_url text;

-- get_agent_card() 재정의 — card-sites.sql 버전에 hero_url 한 줄만 추가.
-- site 하위 객체·조인·grant는 그대로다.
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
    'hero_url',  a.hero_url,
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


-- ── 확인 ───────────────────────────────────────────────────────
select
  (select count(*) from information_schema.columns
     where table_name = 'agent_cards' and column_name = 'hero_url')  as hero_url_생김,
  (select public.get_agent_card('simjunhyung') ? 'hero_url')         as 카드에_hero_url_키_있음;
