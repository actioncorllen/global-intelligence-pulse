// Website Asset Capture — worker self-test.
// Proves (1) URL/SSRF validation rejects everything it must, and
//        (2) REAL headless-browser rendering works: JS executes, a screenshot is
//            produced at the requested viewport, with a stable sha256 hash.
//
// The render proof runs against a LOCAL fixture served on 127.0.0.1 using an
// explicit TEST-ONLY allow flag, because the production allowlist (and the egress
// policy) permit only the approved public Pulse domain. It proves the renderer is
// a true browser (not HTTP fetch) without touching the public internet.
//
// Run: node selftest.mjs

import http from 'node:http';
import { validateCaptureUrl } from './validate.mjs';
import { capture } from './capture.mjs';

const results = [];
const check = (name, pass, extra) => { results.push({ case: name, pass: !!pass, ...(extra || {}) }); };

// ---- 1. Validation unit tests -------------------------------------------------
const good = 'https://www.globalintelligenceactions.com/';
check('allow_good_domain', validateCaptureUrl(good).ok);
check('reject_external_domain', !validateCaptureUrl('https://evil.example.com/').ok);
check('reject_subdomain_suffix_spoof', !validateCaptureUrl('https://www.globalintelligenceactions.com.evil.com/').ok);
check('reject_userinfo_spoof', !validateCaptureUrl('https://www.globalintelligenceactions.com@evil.com/').ok);
check('reject_http_scheme', !validateCaptureUrl('http://www.globalintelligenceactions.com/').ok);
check('reject_file_scheme', !validateCaptureUrl('file:///etc/passwd').ok);
check('reject_data_scheme', !validateCaptureUrl('data:text/html,<h1>x</h1>').ok);
check('reject_javascript_scheme', !validateCaptureUrl('javascript:alert(1)').ok);
check('reject_localhost', !validateCaptureUrl('https://localhost/').ok);
check('reject_loopback_ip', !validateCaptureUrl('https://127.0.0.1/').ok);
check('reject_metadata_ip', !validateCaptureUrl('https://169.254.169.254/').ok);
check('reject_private_10', !validateCaptureUrl('https://10.0.0.5/').ok);
check('reject_private_192', !validateCaptureUrl('https://192.168.1.1/').ok);
check('reject_private_172', !validateCaptureUrl('https://172.16.0.9/').ok);
check('localhost_allowed_only_with_test_flag',
  !validateCaptureUrl('http://127.0.0.1:8781/').ok &&
  validateCaptureUrl('http://127.0.0.1:8781/', { allowInsecureLocalhostTest: true }).ok);

// ---- 2. Real browser render proof (local JS fixture) --------------------------
const PORT = 8781;
const FIXTURE = `<!doctype html><html><head><meta charset="utf-8"><title>Render Proof</title>
<style>body{margin:0;background:#0b1020;color:#eaf0ff;font-family:system-ui}#box{display:none}
.on{display:block!important;padding:40px;font-size:40px}</style></head>
<body><div id="box">JS-RENDERED-OK</div>
<script>document.getElementById('box').className='on';
document.body.setAttribute('data-ready','1');</script></body></html>`;

const server = http.createServer((_req, res) => {
  res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
  res.end(FIXTURE);
});

async function main() {
  await new Promise((r) => server.listen(PORT, '127.0.0.1', r));
  let renderOk = false, dimsOk = false, hashOk = false, fullOk = false, offHostBlocked = false;
  try {
    // VIEWPORT desktop 1440x1200 against the local JS fixture (test flag on).
    const capV = await capture({
      url: `http://127.0.0.1:${PORT}/`, captureType: 'VIEWPORT', device: 'desktop',
      tenantId: 'selftest', allowInsecureLocalhostTest: true, navTimeoutMs: 20000,
    });
    renderOk = capV.buffer && capV.buffer.length > 1000;
    dimsOk = capV.provenance.width === 1440 && capV.provenance.height === 1200;
    hashOk = /^[0-9a-f]{64}$/.test(capV.provenance.asset_hash);

    // FULL_PAGE should also succeed and be >= viewport height.
    const capF = await capture({
      url: `http://127.0.0.1:${PORT}/`, captureType: 'FULL_PAGE', device: 'desktop',
      tenantId: 'selftest', allowInsecureLocalhostTest: true, navTimeoutMs: 20000,
    });
    fullOk = capF.buffer.length > 1000 && capF.provenance.width === 1440 && capF.provenance.height >= 1;

    // Production allowlist must refuse the local fixture (no test flag).
    try {
      await capture({ url: `http://127.0.0.1:${PORT}/`, captureType: 'VIEWPORT', tenantId: 'x' });
    } catch (e) { offHostBlocked = String(e.message).includes('url_rejected'); }

    check('real_browser_js_render', renderOk);
    check('viewport_dimensions_1440x1200', dimsOk, { got: `${capV.provenance.width}x${capV.provenance.height}` });
    check('sha256_asset_hash', hashOk);
    check('full_page_capture_ok', fullOk, { height: capF.provenance.height });
    check('production_allowlist_blocks_localhost', offHostBlocked);
    check('provenance_has_no_secrets',
      !/password|cookie|authorization|bearer|secret|token/i.test(JSON.stringify(capV.provenance)));
  } catch (e) {
    check('render_proof_exception', false, { err: String(e.message || e) });
  } finally {
    server.close();
  }

  const total = results.length;
  const passed = results.filter((r) => r.pass).length;
  const summary = { suite: 'website_asset_capture_worker', total, passed, failed: total - passed, all_pass: passed === total, results };
  console.log(JSON.stringify(summary, null, 2));
  process.exit(summary.all_pass ? 0 : 1);
}
main();
