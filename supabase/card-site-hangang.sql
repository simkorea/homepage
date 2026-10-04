-- ═══════════════════════════════════════════════════════════════
-- 명함용 현장 등록 — 한강 푸르지오 리버프론트 (slug: hangang)
-- ───────────────────────────────────────────────────────────────
-- Supabase 대시보드 → SQL Editor 에 통째로 붙여넣고 Run.
-- 홍보 이미지 27장 = 조감/조경 CG 2장 + 교육자료 v4 선별 25쪽
--   (입지 5·6·25 / 사업개요 38·39 / 커뮤니티 42·43·44 / 평면 12개 타입 / 분양가 70-74)
-- 이미지는 Storage 에 올리지 않고 배포된 현장 홈페이지의 공개 주소를
-- 그대로 쓴다 — 업로드 단계가 사라지고, 사이트 이미지를 바꾸면 명함도
-- 같이 바뀐다.
--
-- 다시 실행해도 안전하다(같은 slug 면 덮어쓴다).
-- ═══════════════════════════════════════════════════════════════

insert into public.card_sites
  (slug, name, headline, subhead, hero_url, specs, images, notice, address, site_url, published)
values (
  'hangang',
  '한강 푸르지오 리버프론트',
  '마침내 한강 앞에 서다',
  '김포 고촌 한강변 · 지상 38층 12개 동 2,432세대',
  'https://hangang-prugio.vercel.app/images/hp/og-image.jpg',
  '[
    {
        "k": "공급위치",
        "v": "경기도 김포시 고촌읍 향산리 588-45번지 일원"
    },
    {
        "k": "공급규모",
        "v": "지하 4층 ~ 지상 38층, 12개 동, 총 2,432세대"
    },
    {
        "k": "주택형",
        "v": "전용 84㎡(A~F) · 106㎡(A·B) · 122㎡ · 180㎡ 펜트하우스"
    },
    {
        "k": "시공사",
        "v": "㈜대우건설"
    },
    {
        "k": "사업주체",
        "v": "주식회사 한강시네폴리스개발"
    },
    {
        "k": "입주시기",
        "v": "2031년 1월 예정 (정확한 입주일자는 추후 통보)"
    },
    {
        "k": "규제 여부",
        "v": "비규제지역 · 분양가상한제 적용 · 공공택지"
    },
    {
        "k": "전매제한",
        "v": "3년 (기간 내 소유권 이전 등기 시 해제)"
    },
    {
        "k": "견본주택",
        "v": "경기도 김포시 풍무동 368-7"
    }
]'::jsonb,
  '[
    "https://hangang-prugio.vercel.app/images/hp/hero-poster.jpg",
    "https://hangang-prugio.vercel.app/images/card/p05.jpg",
    "https://hangang-prugio.vercel.app/images/card/p06.jpg",
    "https://hangang-prugio.vercel.app/images/card/p25.jpg",
    "https://hangang-prugio.vercel.app/images/card/p38.jpg",
    "https://hangang-prugio.vercel.app/images/card/p39.jpg",
    "https://hangang-prugio.vercel.app/images/hp/ls-feature.jpg",
    "https://hangang-prugio.vercel.app/images/card/p42.jpg",
    "https://hangang-prugio.vercel.app/images/card/p43.jpg",
    "https://hangang-prugio.vercel.app/images/card/p44.jpg",
    "https://hangang-prugio.vercel.app/images/card/p46.jpg",
    "https://hangang-prugio.vercel.app/images/card/p52.jpg",
    "https://hangang-prugio.vercel.app/images/card/p48.jpg",
    "https://hangang-prugio.vercel.app/images/card/p54.jpg",
    "https://hangang-prugio.vercel.app/images/card/p56.jpg",
    "https://hangang-prugio.vercel.app/images/card/p58.jpg",
    "https://hangang-prugio.vercel.app/images/card/p60.jpg",
    "https://hangang-prugio.vercel.app/images/card/p62.jpg",
    "https://hangang-prugio.vercel.app/images/card/p50.jpg",
    "https://hangang-prugio.vercel.app/images/card/p64.jpg",
    "https://hangang-prugio.vercel.app/images/card/p66.jpg",
    "https://hangang-prugio.vercel.app/images/card/p68.jpg",
    "https://hangang-prugio.vercel.app/images/card/p70.jpg",
    "https://hangang-prugio.vercel.app/images/card/p71.jpg",
    "https://hangang-prugio.vercel.app/images/card/p72.jpg",
    "https://hangang-prugio.vercel.app/images/card/p73.jpg",
    "https://hangang-prugio.vercel.app/images/card/p74.jpg"
]'::jsonb,
  '선착순 공급 중입니다. 방문 상담은 사전예약제로 운영되오니 미리 연락 부탁드립니다.',
  '경기도 김포시 풍무동 368-7',
  'https://hangang-prugio.vercel.app/',
  true
)
on conflict (slug) do update set
  name      = excluded.name,
  headline  = excluded.headline,
  subhead   = excluded.subhead,
  hero_url  = excluded.hero_url,
  specs     = excluded.specs,
  images    = excluded.images,
  notice    = excluded.notice,
  address   = excluded.address,
  site_url  = excluded.site_url,
  published = excluded.published;

-- 확인
select slug, name, published,
       jsonb_array_length(specs)  as 사업개요,
       jsonb_array_length(images) as 홍보이미지
from public.card_sites order by slug;
