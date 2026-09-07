-- ═══════════════════════════════════════════════════════════════
-- 분양상담사 디지털 명함 (pentaone / tctilpuhknxucrlnhlky)
-- ───────────────────────────────────────────────────────────────
-- 명함 한 장 = 이 표의 한 행.
--
-- 이전에는 한 사람당 HTML 파일 하나였다. 직원을 추가하려면 파일을
-- 복사하고 고치고 커밋하고 배포해야 했다. 1명당 10분이고 개발자를
-- 거쳐야 해서, 현장 9곳 × 직원 여러 명에는 못 쓴다.
-- 여기로 옮기면 직원 추가가 관리자 페이지에서 행 하나 넣는 일이 되고
-- 배포는 필요 없다.
--
-- 컬럼은 분양명함/index.html 의 PROFILE 객체를 그대로 옮긴 것이다.
-- 처음부터 그러려고 그 모양으로 짜뒀다.
--
-- 함께 보기:
--   분양명함\api\card.js        슬러그로 한 장을 읽어 HTML로 그린다
--   분양명함\api\_template.js   그 HTML 본문
--   홈페이지\admin.html         "명함 관리" 탭에서 이 표를 편집한다
-- ═══════════════════════════════════════════════════════════════


-- ── 1) agent_cards ─────────────────────────────────────────────

create table if not exists public.agent_cards (
  slug        text primary key,        -- 주소가 된다: /{slug}
  name        text not null,
  role        text not null default '분양상담사',
  org         text,                    -- 소속 상호
  org_en      text,                    -- 히어로 상단의 영문 표기
  site        text,                    -- 담당 현장. 현장별로 묶어 볼 때 쓴다

  tel         text,                    -- 대표번호
  mobile      text,                    -- 개인 휴대폰. 있으면 전화·문자 버튼이 이쪽으로 걸린다
  kakao_url   text,                    -- 1:1 오픈채팅 링크. 없으면 버튼이 비활성으로 나온다
  photo_url   text,                    -- Storage 공개 URL. 없으면 이름 첫 글자가 대신 뜬다

  tagline     text,
  about       text,

  -- 화면 구조를 그대로 담는다. 사람마다 항목 수가 달라서 표로 쪼개지 않았다.
  facts       jsonb not null default '[]'::jsonb,  -- [{n:"9", l:"담당 현장"}]
  sites       jsonb not null default '[]'::jsonb,  -- [{nm,ds,url}]
  creds       jsonb not null default '[]'::jsonb,  -- ["2015년 입사", "공인중개사"]

  -- 꺼두면 주소로 들어와도 404다. 내용을 채우는 동안 감춰두는 용도.
  published   boolean not null default false,

  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),

  -- 주소에 그대로 들어가므로 소문자·숫자·하이픈만 받는다.
  -- 한글이나 공백이 들어가면 카카오톡에서 링크가 깨진다.
  constraint agent_cards_slug_format check (slug ~ '^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$')
);

create index if not exists agent_cards_site_idx
  on public.agent_cards using btree (site);

create index if not exists agent_cards_published_idx
  on public.agent_cards using btree (published, name);


-- 수정 시각은 손으로 안 챙긴다
create or replace function public.touch_agent_cards()
returns trigger
language plpgsql
as $fn$
begin
  new.updated_at = now();
  return new;
end
$fn$;

drop trigger if exists agent_cards_touch on public.agent_cards;
create trigger agent_cards_touch
  before update on public.agent_cards
  for each row execute function public.touch_agent_cards();


-- ── 2) 접근 권한 ───────────────────────────────────────────────
-- ⚠️ 익명(anon) 정책을 만들지 않는다. 이 표에는 직원 개인 휴대폰이
--    들어가는데, anon 키는 모든 사이트 소스에 공개돼 있다. SELECT를
--    열어주면 REST 한 번으로 전 직원 연락처를 통째로 긁어갈 수 있다.
--    (ad_clicks 에 뚫려 있던 것과 같은 종류의 구멍이다 —
--     ip-fraud-tables-backup.sql 참고)
--
--    공개 열람은 아래 get_agent_card() 하나로만 나간다.

alter table public.agent_cards enable row level security;

create policy "auth manages agent_cards"
  on public.agent_cards for all to authenticated
  using (true) with check (true);


-- ── 3) get_agent_card(p_slug) ──────────────────────────────────
-- 명함 페이지가 부르는 유일한 통로.
-- 슬러그를 아는 사람에게 published=true 인 카드 "한 장"만 준다.
-- 표를 훑거나 목록을 받아갈 방법이 없다.

create or replace function public.get_agent_card(p_slug text)
returns jsonb
language sql
security definer
set search_path = public
as $fn$
  select to_jsonb(c)
  from (
    select
      slug, name, role, org, org_en, site,
      tel, mobile, kakao_url, photo_url,
      tagline, about, facts, sites, creds
    from public.agent_cards
    where slug = lower(btrim(coalesce(p_slug, '')))
      and published = true
    limit 1
  ) c;
$fn$;

revoke all on function public.get_agent_card(text) from public;
grant execute on function public.get_agent_card(text) to anon, authenticated;


-- ── 4) 사진 보관함 ─────────────────────────────────────────────
-- 프로필 사진을 Storage에 둔다. 사진 때문에 커밋할 일이 없어진다.
-- 명함에 띄울 사진이므로 읽기는 공개, 올리고 지우는 것은 관리자만.

insert into storage.buckets (id, name, public)
values ('agent-photos', 'agent-photos', true)
on conflict (id) do nothing;

drop policy if exists "public reads agent photos" on storage.objects;
create policy "public reads agent photos"
  on storage.objects for select to public
  using (bucket_id = 'agent-photos');

drop policy if exists "auth writes agent photos" on storage.objects;
create policy "auth writes agent photos"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'agent-photos');

drop policy if exists "auth updates agent photos" on storage.objects;
create policy "auth updates agent photos"
  on storage.objects for update to authenticated
  using (bucket_id = 'agent-photos') with check (bucket_id = 'agent-photos');

drop policy if exists "auth deletes agent photos" on storage.objects;
create policy "auth deletes agent photos"
  on storage.objects for delete to authenticated
  using (bucket_id = 'agent-photos');


-- ── 5) 첫 카드 이관 ────────────────────────────────────────────
-- 지금 파일에 박혀 있는 심준형 명함을 그대로 옮긴다.
-- 값은 분양명함/index.html 의 PROFILE 에서 가져온 것이고,
-- 아직 못 받은 항목(휴대폰·카카오·사진·경력)은 비워 둔다.
-- 비어 있으면 화면에서 알아서 감춰지거나 버튼이 비활성으로 나온다.

insert into public.agent_cards (
  slug, name, role, org, org_en, site,
  tel, mobile, kakao_url, photo_url,
  tagline, about, facts, sites, creds, published
) values (
  'simjunhyung', '심준형', '분양상담사', '더 타임즈 플레이스', 'THE TIMES PLACE', null,
  '1555-1087', null, null, null,
  '수도권 분양 현장을 직접 맡아 상담부터 계약까지 함께합니다.',
  '현장에 상주하며 분양 상담을 합니다. 홈페이지·검색광고·콘텐츠까지 직접 운영하기 때문에, '
  || '지금 어떤 현장이 어떤 조건으로 나와 있는지 가장 먼저 압니다. 좋은 말만 하지 않습니다. '
  || '맞지 않는 현장은 맞지 않는다고 말씀드립니다.',
  '[{"n":"9","l":"담당 현장"},{"n":"수도권","l":"주요 권역"},{"n":"직영","l":"현장 운영"}]'::jsonb,
  '[
    {"nm":"상동역 롯데캐슬 시그니처","ds":"부천 상동 7호선 초역세권 49층 1,859세대","url":"https://sangdong-lotte.vercel.app/"},
    {"nm":"두산위브더제니스 부천","ds":"소사역 더블역세권 총 2,008세대 49층","url":"https://bucheon-zenith.vercel.app/"},
    {"nm":"더코리츠힐 남산","ds":"서울 중구 신당동 버티고개역 도보 1분","url":"https://homepage-iota-dun.vercel.app/"},
    {"nm":"양주 옥정중앙역 디에트르","ds":"7호선 옥정중앙역(예정) 초역세권 3,660세대","url":"https://okjeong-detre-zeta.vercel.app/"},
    {"nm":"정동 롯데캐슬 136","ds":"서울 중구 순화동 프리미엄 분양","url":"https://jeongdong-lotte136.vercel.app/"},
    {"nm":"파크로쉬 서울원","ds":"광운대역세권, 새로운 삶의 방식","url":"https://parkroche-homepage.vercel.app/"},
    {"nm":"목동 윤슬자이","ds":"양천구 목동 오피스텔 651실","url":"https://mokdong-yunseul-xi.vercel.app/"},
    {"nm":"카일룸 밤섬","ds":"한강·밤섬 조망 28세대","url":"https://caelum-homepage.vercel.app/"},
    {"nm":"PH1603","ds":"서초구 남부터미널역 도보 2분","url":"https://ph1603-homepage.vercel.app/"}
  ]'::jsonb,
  '[]'::jsonb,
  true
)
on conflict (slug) do nothing;


-- ── 확인 ───────────────────────────────────────────────────────
select
  (select count(*) from public.agent_cards)                        as 카드수,
  (select count(*) from public.agent_cards where published)        as 공개중,
  (select public.get_agent_card('simjunhyung') ->> 'name')         as 조회_이름,
  (select public.get_agent_card('없는슬러그') is null)              as 없는건_null;
