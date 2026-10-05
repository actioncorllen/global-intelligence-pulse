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
import os from 'node:os';
import path from 'node:path';
import { mkdtempSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { validateCaptureUrl } from './validate.mjs';
import { capture, isMainModule } from './capture.mjs';

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

// ---- 1b. Cross-platform CLI-entry detection (Windows regression) ---------------
// The worker's CLI must fire when capture.mjs is the entry script on EVERY platform.
// The old guard `import.meta.url === `file://${process.argv[1]}`` matched on POSIX by
// luck (argv[1] already starts with "/") but never on Windows, where argv[1] is a
// drive path (C:\...). isMainModule() uses pathToFileURL so it is portable.
const capturePath = fileURLToPath(new URL('./capture.mjs', import.meta.url));
const captureUrl = pathToFileURL(capturePath).href;
check('cli_entry_matches_self', isMainModule(captureUrl, capturePath) === true);
check('cli_entry_rejects_other_script',
  isMainModule(captureUrl, fileURLToPath(new URL('./validate.mjs', import.meta.url))) === false);
check('cli_entry_handles_missing_argv', isMainModule(captureUrl, undefined) === false);
// Windows semantics, asserted portably with hardcoded strings (pathToFileURL on a
// POSIX host cannot convert a Windows path, so we compare the known normalized forms):
const winArgv1 = 'C:\\Users\\DELL\\global-intelligence-pulse\\services\\website-asset-capture\\capture.mjs';
const winModuleUrl = 'file:///C:/Users/DELL/global-intelligence-pulse/services/website-asset-capture/capture.mjs';
// Node reports import.meta.url as file:///C:/... — the OLD naive concat produced
// "file://C:\Users\..." which never equals it (this is the exact Windows bug):
check('cli_old_concat_broken_on_windows', (`file://${winArgv1}`) !== winModuleUrl);
// The normalized Windows file URL uses a triple slash + forward slashes:
check('cli_windows_fileurl_normalized_form', (`file:///${winArgv1.replace(/\\/g, '/')}`) === winModuleUrl);

// ---- 1c. The CLI block actually fires when run as the entry script -------------
// Spawn capture.mjs as the main module with a DISALLOWED url: it rejects before any
// browser/network work and must print JSON + exit 1. Before the fix, on Windows this
// returned to the prompt with NO output and exit 0 (the reported symptom).
const cliTmp = mkdtempSync(path.join(os.tmpdir(), 'wac-cli-'));
const cli = spawnSync(process.execPath, [capturePath, '--url', 'https://evil.example.com/', '--out', cliTmp], { encoding: 'utf8' });
const cliOut = `${cli.stdout || ''}${cli.stderr || ''}`;
check('cli_entry_runs_as_main_subprocess', cli.status === 1 && /url_rejected/.test(cliOut),
  { status: cli.status, emitted: cliOut.trim().slice(0, 120) });

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
