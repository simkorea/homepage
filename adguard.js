/* ══════════════════════════════════════════════════════════════
   AdGuard — 광고 부정클릭 추적 스크립트
   ──────────────────────────────────────────────────────────────
   설치: </body> 앞에 아래 두 줄을 넣는다.
     <script>window.ADGUARD_SITE = '현장이름';</script>
     <script src="./adguard.js" defer></script>

   동작:
     1. 네이버/구글/메타 광고를 타고 들어온 방문만 기록한다.
        (일반 방문은 기록하지 않아 DB가 불필요하게 커지지 않는다)
     2. IP와 User-Agent는 보내지 않는다. Supabase가 요청 헤더에서
        직접 읽으므로 방문자가 위조할 수 없다.
     3. 페이지를 떠날 때 체류시간과 실제 상호작용 여부를 1회 보낸다.

   주의: 이 스크립트는 광고 클릭 자체를 막지 못한다. 클릭 시점에
   이미 광고비가 과금되기 때문이다. 수집한 근거로 의심 IP를 네이버
   광고노출제한에 등록해 '다음 클릭'을 막고, 무효클릭 환급을
   신청하는 것이 실제 절감 경로다.

   추가로, 같은 IP가 10분 안에 비정상적으로 여러 번 접속하면(가짜
   상담신청·스크래핑 봇 대비) 12회부터 경고를, 20회부터는 페이지
   접속 자체를 일시 차단한다. 통신사 공유IP로 인한 오차단을
   피하려고 기준을 넉넉히 잡았고, 10분이 지나면 자동으로 풀린다.
   네이버·구글 등 검색엔진 수집봇은 이 판정에서 완전히 제외된다
   (서버에서 User-Agent로 걸러내므로 SEO에 영향 없음).
   ══════════════════════════════════════════════════════════════ */
(function () {
  'use strict';

  var SUPABASE_URL = 'https://tctilpuhknxucrlnhlky.supabase.co';
  var SUPABASE_ANON = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRjdGlscHVoa254dWNybG5obGt5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzYxMzE3NjQsImV4cCI6MjA5MTcwNzc2NH0._mS10zf3ayR7nbdFxQJHfZS57_tzOakGm-WkyQB8bxU';

  var SITE = window.ADGUARD_SITE || document.title || location.hostname;

  function post(fn, body, keepalive) {
    return fetch(SUPABASE_URL + '/rest/v1/rpc/' + fn, {
      method: 'POST',
      headers: {
        'apikey': SUPABASE_ANON,
        'Authorization': 'Bearer ' + SUPABASE_ANON,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify(body),
      keepalive: !!keepalive
    });
  }

  // ── 0) 반복 접속 판정 ────────────────────────────────────────
  // 광고 유입 여부와 관계없이 모든 방문에서 실행한다.
  // 판정은 서버(IP 단위)에서 내려지므로 캐시 삭제로 회피할 수 없다.
  (function accessGuard() {
    post('check_site_visit', { p_site: String(SITE).slice(0, 80) })
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(function (result) {
        if (!result) return;
        if (result.status === 'blocked') showBlockOverlay();
        else if (result.status === 'warn') showWarnBanner();
      })
      .catch(function () { /* 판정 실패 시 절대 막지 않는다 */ });
  })();

  function showWarnBanner() {
    try {
      var bar = document.createElement('div');
      bar.textContent = '반복적인 접속이 감지되었습니다. 계속될 경우 일시적으로 접속이 제한될 수 있습니다.';
      bar.style.cssText = 'position:fixed;top:0;left:0;right:0;z-index:2147483000;' +
        'background:#78350f;color:#fef3c7;font-size:13px;line-height:1.5;' +
        'padding:10px 16px;text-align:center;font-family:system-ui,-apple-system,sans-serif;' +
        'box-shadow:0 2px 8px rgba(0,0,0,.25);';
      document.documentElement.appendChild(bar);
      setTimeout(function () { if (bar.parentNode) bar.parentNode.removeChild(bar); }, 8000);
    } catch (e) {}
  }

  // 판정은 네트워크 왕복(수십~수백ms) 후에 도착하므로, 페이지가 잠깐
  // 정상 렌더링된 뒤 화면이 교체된다. <head>는 그대로 두어(뷰포트 메타
  // 태그 등) 모바일에서도 차단 화면이 정상 크기로 보이게 한다.
  function showBlockOverlay() {
    try {
      document.body.style.margin = '0';
      var box = document.createElement('div');
      box.style.cssText = 'position:fixed;inset:0;z-index:2147483647;' +
        'background:#111827;color:#f9fafb;display:flex;align-items:center;justify-content:center;' +
        'flex-direction:column;text-align:center;padding:32px;font-family:system-ui,-apple-system,sans-serif;';
      box.innerHTML =
        '<div style="font-size:40px;margin-bottom:16px;">일시 접속 제한</div>' +
        '<div style="font-size:15px;line-height:1.7;color:#d1d5db;max-width:420px;">' +
        '짧은 시간 동안 반복된 접속이 감지되어 일시적으로 접속이 제한되었습니다.<br>' +
        '약 10분 후 자동으로 해제됩니다.<br><br>' +
        '정상적인 이용 중 표시되었다면 잠시 후 다시 시도해 주세요.</div>';
      document.body.innerHTML = '';
      document.body.appendChild(box);
    } catch (e) {}
  }

  // ── 광고 유입 판별 ───────────────────────────────────────────
  // 네이버 검색광고는 NaPm/nvadId 등을, 구글은 gclid를 붙여 보낸다.
  var AD_PARAMS = [
    'NaPm', 'nvadId', 'n_keyword', 'na_keyword', 'nclicks', 'n_media',
    'n_query', 'n_rank', 'n_ad_group', 'n_campaign_type', 'NaBs',
    'gclid', 'gad_source', 'gbraid', 'wbraid', 'fbclid', 'utm_source'
  ];

  var params = new URLSearchParams(location.search);
  var hits = AD_PARAMS.filter(function (p) { return params.has(p); });
  if (!hits.length) return;   // 광고 유입이 아니면 아무것도 하지 않는다

  // 검색 키워드 (네이버가 실어 보내는 값 중 먼저 잡히는 것)
  var keyword = params.get('n_keyword') || params.get('na_keyword') ||
                params.get('n_query')   || params.get('utm_term')   || '';

  var paramSummary = hits.map(function (p) {
    return p + '=' + (params.get(p) || '').slice(0, 60);
  }).join('&').slice(0, 480);

  // ── 자동화 도구 흔적 ─────────────────────────────────────────
  // 여기서 나온 값은 IP 차단 근거로 쓰인다. 정상 고객을 봇으로 잘못
  // 판정하면 그 사람에게 광고가 안 나가고 손님을 잃는다.
  // 그래서 오탐 위험이 조금이라도 있는 신호는 일부러 제외했다.
  //
  //  제외한 신호와 이유:
  //   - outerWidth/Height === 0  → 카카오톡·네이버 인앱 브라우저에서 흔함
  //   - screen.width === 0       → 일부 웹뷰에서 발생
  //   - plugins.length === 0     → 모바일 브라우저 대부분이 해당
  function detectBotFlags() {
    var f = [];
    var ua = navigator.userAgent || '';
    try {
      // 자동화 브라우저가 스스로 밝히는 값. 오탐이 거의 없다.
      if (navigator.webdriver === true) f.push('webdriver');
      // 크롤러·자동화 도구가 UA에 이름을 그대로 노출하는 경우
      if (/HeadlessChrome|PhantomJS|Puppeteer|Selenium|playwright|scrapy|curl|wget|python-requests|okhttp/i.test(ua)) f.push('bot_ua');
      // 실제 브라우저라면 언어 설정이 비어 있을 수 없다
      if (!navigator.languages || navigator.languages.length === 0) f.push('no_lang');
      // 자동화 도구가 주입하는 전역 객체
      if (window._phantom || window.callPhantom || window.__nightmare ||
          window.__selenium_unwrapped || window.__webdriver_evaluate) f.push('phantom');
    } catch (e) { /* 탐지 실패는 무시 */ }
    return f.join(',');
  }

  // ── 단말 지문 ────────────────────────────────────────────────
  // IP가 바뀌어도 같은 기기를 알아보기 위한 대략적 식별자.
  // 개인을 특정하려는 목적이 아니라 반복 클릭 묶음을 찾기 위한 값이다.
  function makeFingerprint() {
    var parts = [
      navigator.userAgent, navigator.language,
      screen.width + 'x' + screen.height, screen.colorDepth,
      navigator.platform || '', navigator.hardwareConcurrency || '',
      navigator.deviceMemory || '',
      (Intl.DateTimeFormat().resolvedOptions().timeZone || '')
    ].join('|');

    var h1 = 0x811c9dc5, h2 = 0x01000193;
    for (var i = 0; i < parts.length; i++) {
      var c = parts.charCodeAt(i);
      h1 = (h1 ^ c) >>> 0; h1 = Math.imul(h1, 0x01000193) >>> 0;
      h2 = (h2 + c) >>> 0; h2 = Math.imul(h2, 0x85ebca6b) >>> 0;
    }
    return (h1.toString(16) + h2.toString(16)).slice(0, 32);
  }

  // ── 1) 유입 기록 ─────────────────────────────────────────────
  var clickId = null;
  var startedAt = Date.now();

  post('log_ad_click', {
    p_site: String(SITE).slice(0, 80),
    p_param: paramSummary,
    p_keyword: keyword.slice(0, 200),
    p_referrer: (document.referrer || '').slice(0, 300),
    p_landing_path: (location.pathname + location.search).slice(0, 300),
    p_fingerprint: makeFingerprint(),
    p_bot_flags: detectBotFlags()
  })
    .then(function (r) { return r.ok ? r.json() : null; })
    .then(function (id) { if (id) clickId = id; })
    .catch(function () { /* 추적 실패가 페이지를 망가뜨리면 안 된다 */ });

  // ── 2) 실제 상호작용 관찰 ────────────────────────────────────
  // 사람이라면 스크롤하거나 마우스를 움직이거나 무언가를 누른다.
  var engaged = false;
  var moves = 0;

  function markEngaged() { engaged = true; cleanup(); }

  function onMove() { if (++moves >= 3) markEngaged(); }
  function onScroll() { if (window.scrollY > 100) markEngaged(); }

  function cleanup() {
    window.removeEventListener('mousemove', onMove);
    window.removeEventListener('scroll', onScroll);
    window.removeEventListener('touchstart', markEngaged);
    window.removeEventListener('click', markEngaged);
    window.removeEventListener('keydown', markEngaged);
  }

  window.addEventListener('mousemove', onMove, { passive: true });
  window.addEventListener('scroll', onScroll, { passive: true });
  window.addEventListener('touchstart', markEngaged, { passive: true });
  window.addEventListener('click', markEngaged, { passive: true });
  window.addEventListener('keydown', markEngaged, { passive: true });

  // ── 3) 이탈 시 1회 전송 ──────────────────────────────────────
  var sent = false;
  function sendEngagement() {
    if (sent || !clickId) return;
    sent = true;
    post('update_ad_click_engagement', {
      p_id: clickId,
      p_dwell_ms: Date.now() - startedAt,
      p_engaged: engaged
    }, true).catch(function () {});
  }

  window.addEventListener('pagehide', sendEngagement);
  document.addEventListener('visibilitychange', function () {
    if (document.visibilityState === 'hidden') sendEngagement();
  });
})();
