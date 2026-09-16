-- ═══════════════════════════════════════════════════════════════
-- 명함 리드 이메일 알림 (pentaone / tctilpuhknxucrlnhlky)
-- ───────────────────────────────────────────────────────────────
-- 명함에서 상담 문의·방문예약이 들어오면 그 담당 직원 본인 이메일로
-- 알림을 보낸다. 지금은 consultations에 저장만 되고 admin.html을
-- 열어봐야 안다.
--
-- 처음엔 문자(SMS)로 하려 했으나 발송 업체 계정 개설 + 사업자등록번호로
-- 사전 등록한 발신번호가 필요해 문턱이 있었다. 이메일은 다른 현장
-- 사이트들의 api/consult.js가 이미 Resend로 보내고 있어 새 계정이
-- 필요 없다 — 그래서 이메일로 먼저 간다.
--
-- 알림을 "클라이언트가 제출 성공 후 한 번 더 호출"하는 방식으로 만들면,
-- 방문자가 제출 직후 바로 창을 닫는 흔한 경우에 알림이 조용히 유실된다.
-- 리드 하나가 곧 수수료인 상품에서 이 유실은 그냥 넘길 손해가 아니라서,
-- DB 쪽에서 직접 처리한다: Supabase 대시보드의 Database → Webhooks로
-- consultations INSERT에 Edge Function(card-lead-notify)을 건다.
-- 대시보드가 pg_net 활성화와 서비스키 서명을 대신 처리해준다.
--
--   대상 테이블: public.consultations
--   이벤트:      INSERT
--   호출 URL:    https://tctilpuhknxucrlnhlky.supabase.co/functions/v1/card-lead-notify
--
-- 대시보드 웹훅에는 조건 필터가 없어 명함이 아닌 다른 현장의 상담문의
-- (같은 테이블을 쓴다)에도 일단 호출은 간다 — card-lead-notify 안에서
-- source가 '명함-'로 시작하지 않으면 즉시 스킵한다. 이 호출량에서는
-- 무시할 비용이라 트리거에 WHEN절을 다는 것까지는 안 한다.
--
-- 아래는 대시보드에서 만든 것을 문서화(감사 추적용)만 하는 것이다.
-- 실제 웹훅은 대시보드 화면에서 만들었고, 이 파일을 실행한다고 웹훅이
-- 생기지 않는다.
--
-- 함께 보기:
--   supabase\functions\card-lead-notify\index.ts   실제 알림 로직
-- ═══════════════════════════════════════════════════════════════

-- 대시보드가 이미 켰다면 no-op. 수동으로 SQL 트리거를 짤 게 아니면
-- 사실 이 줄도 대시보드가 알아서 처리하지만, 기록 삼아 남긴다.
create extension if not exists pg_net;

-- 알림을 어느 이메일로 보낼지는 담당 직원 카드에 직접 적어둔다.
-- get_agent_card()로는 절대 안 내보낸다 — 공개 RPC에 이메일까지
-- 실어보낼 이유가 없다. card-lead-notify 함수는 서비스키로 이 표를
-- 직접 읽으므로 RPC를 거칠 필요가 없다.
alter table public.agent_cards
  add column if not exists email text;


-- ── 확인 ───────────────────────────────────────────────────────
select
  (select count(*) from information_schema.columns
     where table_name = 'agent_cards' and column_name = 'email')     as email_컬럼_생김,
  (select public.get_agent_card('simjunhyung') ? 'email')            as 공개RPC에_email_없어야함_false;
