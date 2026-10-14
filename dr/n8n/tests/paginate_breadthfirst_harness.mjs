// Offline harness for the BREADTH-FIRST (round-robin) Paginate CJ loop.
// Guarantees: every canonical query's page 1 is examined before any query goes deeper;
// per-query stop (partial/last page, error-after-retry, max pages) preserved; global
// candidate + api-call budgets never exceeded; pacing/retry live-only; mock path untouched.

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
    const done = new Array(queries.length).fill(false);
    let collected = 0, apiCalls = 0;
    // Round-robin: round r fetches page r of every still-active query, in order.
    for (let round = 1; round <= maxPages; round++) {
      let anyActive = false;
      for (let qi = 0; qi < queries.length; qi++) {
        if (done[qi]) continue;
        if (collected >= maxCandidates || apiCalls >= maxApiCalls) { done[qi] = true; continue; }
        anyActive = true;
        const q = queries[qi];
        const pageNum = round;
        let http = 0, body = null, attempts = 0;
        if (mock) {
          const arr = Array.isArray(mock[q]) ? mock[q] : [];
          const mp = arr[pageNum - 1];
          if (!mp) { done[qi] = true; continue; }
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
        if (isError || rowCount < pageSize || pageNum >= maxPages || collected >= maxCandidates) done[qi] = true;
      }
      if (!anyActive) break;
      if (collected >= maxCandidates || apiCalls >= maxApiCalls) break;
    }
    return { pages, page_count: pages.length, api_calls: apiCalls, sleeps, collected };
  })();
}

const full = (n, tag) => ({ statusCode: 200, body: { code: 200, result: true, message: 'Success', data: { list: Array.from({ length: n }, (_, i) => ({ pid: (tag || 'P') + '-' + Math.random().toString(36).slice(2) })) } } });
const throttleThrow = () => { throw new Error('ETIMEDOUT'); };
function assert(name, cond, extra) { console.log((cond ? 'PASS' : 'FAIL') + ' :: ' + name + (extra ? '  ' + extra : '')); if (!cond) process.exitCode = 1; }

// BF1 + BF2: representation guarantee. 8 queries, all full pages of 20, budget 200.
// Expect: page 1 of ALL 8 queries fetched before cap; then page 2 of first queries until 200.
await (async () => {
  const queries = ['q1','q2','q3','q4','q5','q6','q7','q8'];
  const r = await makeLoop({ queries, budget: { page_size: 20, max_pages_per_query: 5, max_candidates: 200, max_api_calls: 40 }, httpImpl: async () => full(20) });
  const page1Queries = new Set(r.pages.filter(p => p.page_num === 1).map(p => p.query));
  assert('BF1 all 8 queries got page 1 (representation)', page1Queries.size === 8, 'got=' + page1Queries.size);
  assert('BF2 candidate budget respected (collected<=200... fetched to cap)', r.collected >= 200 && r.collected <= 200 + 20);
  // total pages: 8 (page1) + 2 (page2 of q1,q2) = 10
  assert('BF2 total pages == 10 (8 page1 + 2 page2)', r.page_count === 10, 'pages=' + r.page_count);
  const page2Queries = r.pages.filter(p => p.page_num === 2).map(p => p.query);
  assert('BF2 depth only on earliest queries after all represented', JSON.stringify(page2Queries) === JSON.stringify(['q1','q2']), JSON.stringify(page2Queries));
})();

// BF3: a query with a partial page-1 (last page) is not fetched again; others go deep.
await (async () => {
  let callN = 0;
  const impl = async (opts) => {
    const q = opts.qs.productNameEn; const p = opts.qs.pageNum;
    if (q === 'q2' && p === 1) return full(5, 'q2');     // partial -> q2 done after page1
    return full(20, q + 'p' + p);
  };
  const r = await makeLoop({ queries: ['q1','q2','q3'], budget: { page_size: 20, max_pages_per_query: 3, max_candidates: 1000, max_api_calls: 40 }, httpImpl: impl });
  const q2pages = r.pages.filter(p => p.query === 'q2').map(p => p.page_num);
  assert('BF3 q2 (partial page1) fetched only page 1', JSON.stringify(q2pages) === JSON.stringify([1]), JSON.stringify(q2pages));
  const q1pages = r.pages.filter(p => p.query === 'q1').map(p => p.page_num);
  assert('BF3 q1 goes to max depth (3 pages)', JSON.stringify(q1pages) === JSON.stringify([1,2,3]), JSON.stringify(q1pages));
})();

// BF4: a query whose page-1 errors (persistent throttle, after retry) is done; others continue.
await (async () => {
  const impl = async (opts) => { if (opts.qs.productNameEn === 'q2') throttleThrow(); return full(20); };
  const r = await makeLoop({ queries: ['q1','q2','q3'], budget: { page_size: 20, max_pages_per_query: 2, max_candidates: 1000, max_api_calls: 40 }, httpImpl: impl });
  const q2pages = r.pages.filter(p => p.query === 'q2');
  assert('BF4 q2 error recorded once (page1 only), attempts==2 (retried)', q2pages.length === 1 && q2pages[0].attempts === 2 && q2pages[0].http_status === 0, JSON.stringify(q2pages.map(p=>({p:p.page_num,a:p.attempts,h:p.http_status}))));
  assert('BF4 q1 and q3 still fetched to depth 2', r.pages.filter(p=>p.query==='q1').length===2 && r.pages.filter(p=>p.query==='q3').length===2);
})();

// BF5: api-call ceiling respected under heavy retry.
await (async () => {
  const r = await makeLoop({ queries: ['q1','q2','q3','q4','q5'], budget: { page_size: 20, max_pages_per_query: 5, max_candidates: 1000, max_api_calls: 7 }, httpImpl: async () => { throttleThrow(); } });
  assert('BF5 api_calls never exceeds budget (<=7)', r.api_calls <= 7, 'api_calls=' + r.api_calls);
})();

// BF6: pacing between live calls; first call no sleep.
await (async () => {
  const r = await makeLoop({ queries: ['q1','q2'], budget: { page_size: 20, max_pages_per_query: 1, max_candidates: 1000, max_api_calls: 40 }, httpImpl: async () => full(20) });
  // 2 calls (page1 of q1,q2), pacing before call#2 only => 1 sleep
  assert('BF6 one pace sleep (no sleep before first call)', r.sleeps.length === 1 && r.sleeps[0] === 1300, JSON.stringify(r.sleeps));
})();

// BF7: mock path (round-indexed) works, zero api calls / zero sleeps.
await (async () => {
  const mock = {
    q1: [ { http_status: 200, body: { data: { list: [{ pid: 'a1' }] } } } ],  // partial -> q1 done after page1
    q2: [ { http_status: 200, body: { data: { list: Array.from({length:20},(_,i)=>({pid:'b'+i})) } } },
          { http_status: 200, body: { data: { list: [{ pid: 'b20' }] } } } ]   // page1 full, page2 partial
  };
  const r = await makeLoop({ queries: ['q1','q2'], budget: { page_size: 20, max_pages_per_query: 5, max_candidates: 200, max_api_calls: 40 }, mock, httpImpl: async () => { throw new Error('mock must not call http'); } });
  assert('BF7 mock: 0 api calls, 0 sleeps', r.api_calls === 0 && r.sleeps.length === 0);
  // Round-robin order: q1p1, q2p1, (q1 done), q2p2
  const order = r.pages.map(p => p.query + 'p' + p.page_num);
  assert('BF7 round-robin order q1p1,q2p1,q2p2', JSON.stringify(order) === JSON.stringify(['q1p1','q2p1','q2p2']), JSON.stringify(order));
})();

console.log('\nDONE');
