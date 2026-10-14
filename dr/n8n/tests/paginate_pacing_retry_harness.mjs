// Local, offline harness for the Paginate CJ loop logic (pacing + bounded retry + budget).
// No CJ, no network. Simulates httpRequest outcomes to prove: retry recovers a transient
// throttle; genuine errors are not retried; the api-call budget is never exceeded; pacing
// delays are applied only to live calls. Uses a tiny PACE/BACKOFF so the harness is fast.

function makeLoop({ queries, budget, httpImpl, token = 'TKN', mock = null }) {
  const pageSize = Number(budget.page_size) || 20;
  const maxPages = Number(budget.max_pages_per_query) || 5;
  const maxCandidates = Number(budget.max_candidates) || 200;
  const maxApiCalls = Number(budget.max_api_calls) || 40;
  const PACE_MS = Number(budget.pace_ms) || 1300;
  const RETRY_BACKOFF_MS = Number(budget.retry_backoff_ms) || 2600;
  const MAX_ATTEMPTS = Number(budget.max_attempts_per_page) || 2;
  const sleeps = [];
  const sleep = (ms) => { sleeps.push(ms); return Promise.resolve(); };
  const helpers = { httpRequest: httpImpl };

  return (async () => {
    const pages = [];
    let collected = 0, apiCalls = 0;
    for (const q of queries) {
      for (let pageNum = 1; pageNum <= maxPages; pageNum++) {
        if (collected >= maxCandidates || apiCalls >= maxApiCalls) break;
        let http = 0, body = null, attempts = 0;
        if (mock) {
          const arr = Array.isArray(mock[q]) ? mock[q] : [];
          const mp = arr[pageNum - 1];
          if (!mp) break;
          http = (mp.http_status != null) ? mp.http_status : 200;
          body = (mp.body != null) ? mp.body : mp;
        } else {
          for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
            if (apiCalls >= maxApiCalls) break;
            if (apiCalls > 0) { await sleep(attempt === 1 ? PACE_MS : RETRY_BACKOFF_MS); }
            apiCalls++; attempts++;
            try {
              const resp = await helpers.httpRequest({ method: 'GET', url: 'x', qs: { pageNum, pageSize, productNameEn: q }, headers: token ? { 'CJ-Access-Token': token } : {}, json: true, timeout: 30000, returnFullResponse: true });
              http = resp.statusCode || 200; body = resp.body || {};
            } catch (err) {
              http = (err && (err.statusCode || err.httpCode || (err.response && err.response.statusCode))) || 0;
              body = (err && err.response && err.response.body) || {};
            }
            const rlist = (body && body.data && Array.isArray(body.data.list)) ? body.data.list : null;
            const msg = String((body && body.message) || '');
            const bodyThrottle = !!(body && body.result === false && /too\s*much|too\s*many|frequent|qps|exceed|limit|interval|per\s*second|请求/i.test(msg));
            const transient = (http === 0) || (http === 429) || (http >= 500) || bodyThrottle;
            if (!transient) break;
          }
        }
        pages.push({ query: q, page_num: pageNum, http_status: http, body: body, attempts });
        let rows = null;
        try { rows = (body && body.data && Array.isArray(body.data.list)) ? body.data.list : null; } catch (e) { rows = null; }
        const isError = (http >= 400) || (http === 0) || (rows === null);
        const rowCount = rows ? rows.length : 0;
        if (!isError) { for (const r of rows) { if (r && r.pid != null) collected++; } }
        if (isError || rowCount < pageSize || pageNum >= maxPages || collected >= maxCandidates) break;
      }
      if (collected >= maxCandidates || apiCalls >= maxApiCalls) break;
    }
    return { pages, page_count: pages.length, api_calls: apiCalls, sleeps, collected };
  })();
}

const full = (n) => ({ statusCode: 200, body: { code: 200, result: true, message: 'Success', data: { list: Array.from({ length: n }, (_, i) => ({ pid: Math.random().toString(36).slice(2) })) } } });
const throttleThrow = () => { const e = new Error('ETIMEDOUT'); throw e; };
const throttle429 = () => ({ statusCode: 429, body: { code: 1600200, result: false, message: 'Too much request, QPS exceeds the limit' } });
const throttleBody200 = () => ({ statusCode: 200, body: { code: 1600200, result: false, message: 'request too frequent, 1 time per second' } });
const client404 = () => ({ statusCode: 404, body: { code: 404, result: false, message: 'not found' } });

function assert(name, cond, extra) { console.log((cond ? 'PASS' : 'FAIL') + ' :: ' + name + (extra ? '  ' + extra : '')); if (!cond) process.exitCode = 1; }

const results = {};

// T1: single query, first attempt THROWS, retry SUCCEEDS -> page recorded as success (http 200), 2 api calls, 1 pace sleep.
await (async () => {
  let n = 0;
  const r = await makeLoop({ queries: ['q1'], budget: { page_size: 20, max_pages_per_query: 1, max_candidates: 200, max_api_calls: 40 }, httpImpl: async () => { n++; if (n === 1) throttleThrow(); return full(5); } });
  assert('T1 retry recovers transient throw: final page http=200', r.pages[0].http_status === 200, JSON.stringify({ attempts: r.pages[0].attempts, api_calls: r.api_calls, sleeps: r.sleeps }));
  assert('T1 attempts==2', r.pages[0].attempts === 2);
  assert('T1 api_calls==2', r.api_calls === 2);
  assert('T1 one backoff sleep applied (retry only, apiCalls>0)', r.sleeps.length === 1);
})();

// T2: 429 then success (body-level throttle via HTTP 429) -> retry recovers.
await (async () => {
  let n = 0;
  const r = await makeLoop({ queries: ['q1'], budget: { page_size: 20, max_pages_per_query: 1, max_candidates: 200, max_api_calls: 40 }, httpImpl: async () => { n++; if (n === 1) return throttle429(); return full(3); } });
  assert('T2 429-then-success recovers: http=200', r.pages[0].http_status === 200);
  assert('T2 attempts==2', r.pages[0].attempts === 2);
})();

// T3: HTTP 200 body-level throttle then success -> retry recovers.
await (async () => {
  let n = 0;
  const r = await makeLoop({ queries: ['q1'], budget: { page_size: 20, max_pages_per_query: 1, max_candidates: 200, max_api_calls: 40 }, httpImpl: async () => { n++; if (n === 1) return throttleBody200(); return full(2); } });
  assert('T3 body-200-throttle recovers: http=200 and has list', r.pages[0].http_status === 200 && Array.isArray(r.pages[0].body.data.list));
  assert('T3 attempts==2', r.pages[0].attempts === 2);
})();

// T4: genuine client error (404) -> NOT retried (attempts==1), recorded as error page.
await (async () => {
  let n = 0;
  const r = await makeLoop({ queries: ['q1'], budget: { page_size: 20, max_pages_per_query: 1, max_candidates: 200, max_api_calls: 40 }, httpImpl: async () => { n++; return client404(); } });
  assert('T4 client 404 not retried: attempts==1', r.pages[0].attempts === 1, JSON.stringify({ http: r.pages[0].http_status }));
  assert('T4 http recorded 404', r.pages[0].http_status === 404);
})();

// T5: persistent throttle (always throws) -> exhausts MAX_ATTEMPTS (2), records error page http=0, stops that query.
await (async () => {
  const r = await makeLoop({ queries: ['q1', 'q2'], budget: { page_size: 20, max_pages_per_query: 3, max_candidates: 200, max_api_calls: 40 }, httpImpl: async () => { throttleThrow(); } });
  assert('T5 persistent throttle: q1 page1 attempts==2', r.pages[0].attempts === 2);
  assert('T5 persistent throttle: q1 stops after error (only 1 page for q1)', r.pages.filter(p => p.query === 'q1').length === 1);
  assert('T5 q2 still attempted (does not abort whole run)', r.pages.some(p => p.query === 'q2'));
})();

// T6: budget ceiling respected under heavy retry. Every call throttles; small budget.
await (async () => {
  const r = await makeLoop({ queries: ['q1', 'q2', 'q3', 'q4', 'q5'], budget: { page_size: 20, max_pages_per_query: 5, max_candidates: 200, max_api_calls: 7 }, httpImpl: async () => { throttleThrow(); } });
  assert('T6 api_calls never exceeds budget (<=7)', r.api_calls <= 7, 'api_calls=' + r.api_calls);
})();

// T7: candidate budget stops the run; full pages of 20.
await (async () => {
  const r = await makeLoop({ queries: ['q1', 'q2', 'q3'], budget: { page_size: 20, max_pages_per_query: 5, max_candidates: 50, max_api_calls: 40 }, httpImpl: async () => full(20) });
  assert('T7 collected >= max_candidates stop (collected>=50)', r.collected >= 50, 'collected=' + r.collected);
  assert('T7 did not exhaust api budget', r.api_calls < 40);
})();

// T8: pacing applied between live calls (apiCalls>0) but NOT before the very first call.
await (async () => {
  let n = 0;
  const r = await makeLoop({ queries: ['q1'], budget: { page_size: 20, max_pages_per_query: 3, max_candidates: 200, max_api_calls: 40 }, httpImpl: async () => { n++; return full(20); } });
  // 3 full pages -> 3 calls, pacing before calls 2 and 3 only => 2 sleeps, all PACE_MS (no retries)
  assert('T8 no sleep before first call; pace before subsequent', r.sleeps.length === 2, 'sleeps=' + JSON.stringify(r.sleeps));
  assert('T8 pacing uses PACE_MS (1300)', r.sleeps.every(s => s === 1300));
})();

// T9: MOCK path unaffected (no sleeps, no api calls, deterministic).
await (async () => {
  const mock = { q1: [{ http_status: 200, body: { data: { list: [{ pid: 'a' }, { pid: 'b' }] } } }] };
  const r = await makeLoop({ queries: ['q1'], budget: { page_size: 20, max_pages_per_query: 2, max_candidates: 200, max_api_calls: 40 }, mock, httpImpl: async () => { throw new Error('should not be called in mock mode'); } });
  assert('T9 mock path makes zero api calls', r.api_calls === 0);
  assert('T9 mock path applies zero sleeps', r.sleeps.length === 0);
  assert('T9 mock page recorded (http 200, 2 pids)', r.pages[0].http_status === 200 && r.pages[0].body.data.list.length === 2);
})();

// T10: empty successful result (list:[]) -> not transient, not retried, stops query (last page).
await (async () => {
  const r = await makeLoop({ queries: ['q1'], budget: { page_size: 20, max_pages_per_query: 5, max_candidates: 200, max_api_calls: 40 }, httpImpl: async () => ({ statusCode: 200, body: { code: 200, result: true, message: 'Success', data: { list: [] } } }) });
  assert('T10 empty success not retried: attempts==1', r.pages[0].attempts === 1);
  assert('T10 only one page (partial/last-page stop)', r.pages.length === 1);
})();

console.log('\nDONE');
