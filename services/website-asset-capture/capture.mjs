// Website Asset Capture — reusable headless-browser capture worker.
// STRATELOQ-WEBSITE-ASSET-CAPTURE-001. PUBLIC ROUTES ONLY.
//
// Real browser rendering (Playwright + Chromium). NEVER plain HTTP fetching.
// Captures a REAL public Pulse page, computes a sha256 asset hash, writes the
// PNG + a secret-free provenance JSON, and (optionally) returns the exact params
// for the fn_website_capture_register RPC. It does NOT approve anything.
//
// Node >= 20. Playwright is resolved from the global install when not local.
// Usage:
//   node capture.mjs --url https://www.globalintelligenceactions.com/ \
//        --type VIEWPORT --device desktop --out ./out
//
// Viewport contract (overridable via --w/--h):
//   desktop = 1440 x 1200 ; mobile = 390 x 844
// Capture types: VIEWPORT | FULL_PAGE  (ELEMENT reserved — pass --selector later)

import { createRequire } from 'node:module';
import { createHash } from 'node:crypto';
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { validateCaptureUrl, assertNoRedirectEscape, DEFAULT_ALLOW_HOSTS } from './validate.mjs';

const require = createRequire(import.meta.url);
function loadPlaywright() {
  for (const p of ['playwright', '/opt/node22/lib/node_modules/playwright']) {
    try { return require(p); } catch { /* try next */ }
  }
  throw new Error('playwright not found (install with `npm i playwright` or use the global one)');
}

export const VIEWPORTS = {
  desktop: { width: 1440, height: 1200, isMobile: false, deviceScaleFactor: 1 },
  mobile: { width: 390, height: 844, isMobile: true, deviceScaleFactor: 3 },
};

function pngDimensions(buf) {
  // PNG IHDR: width = bytes 16..19, height = 20..23 (big-endian).
  if (buf.length < 24 || buf.toString('ascii', 1, 4) !== 'PNG') return { width: null, height: null };
  return { width: buf.readUInt32BE(16), height: buf.readUInt32BE(20) };
}

// Capture one screenshot. Returns { buffer, provenance, storagePath }.
export async function capture({
  url,
  captureType = 'VIEWPORT',          // VIEWPORT | FULL_PAGE
  device = 'desktop',                // desktop | mobile
  viewport,                          // optional explicit {width,height}
  tenantId,
  allowHosts = DEFAULT_ALLOW_HOSTS,
  allowInsecureLocalhostTest = false, // TEST ONLY
  navTimeoutMs = 45000,
} = {}) {
  const v0 = validateCaptureUrl(url, { allowHosts, allowInsecureLocalhostTest });
  if (!v0.ok) throw new Error(`url_rejected:${v0.reason}`);
  if (!['VIEWPORT', 'FULL_PAGE'].includes(captureType)) throw new Error(`bad_capture_type:${captureType}`);

  const vp = viewport || VIEWPORTS[device] || VIEWPORTS.desktop;
  const pw = loadPlaywright();

  const launchArgs = { headless: true, args: ['--no-sandbox', '--disable-dev-shm-usage'] };
  if (process.env.PW_CHROMIUM_PATH || process.env.PLAYWRIGHT_BROWSERS_PATH) {
    launchArgs.executablePath = process.env.PW_CHROMIUM_PATH || '/opt/pw-browsers/chromium';
  }
  // Route outbound through the environment proxy when present (egress policy applies).
  if (process.env.HTTPS_PROXY) launchArgs.proxy = { server: process.env.HTTPS_PROXY };

  const browser = await pw.chromium.launch(launchArgs);
  try {
    const context = await browser.newContext({
      viewport: { width: vp.width, height: vp.height },
      deviceScaleFactor: vp.deviceScaleFactor || 1,
      isMobile: !!vp.isMobile,
      userAgent: vp.isMobile
        ? 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Mobile Safari/604.1'
        : undefined,
    });

    // SSRF guard at the network layer: abort any request to a private/reserved/
    // non-http(s) target; block top-level navigations that leave the allowlist.
    await context.route('**/*', (route) => {
      const req = route.request();
      const rurl = req.url();
      try {
        const ru = new URL(rurl);
        if (!['http:', 'https:'].includes(ru.protocol)) return route.abort();
        // Top-level document navigations must stay on the allowlist (unless test).
        if (req.isNavigationRequest() && !req.frame().parentFrame()) {
          const vv = validateCaptureUrl(rurl, { allowHosts, allowInsecureLocalhostTest });
          if (!vv.ok) return route.abort();
        }
        return route.continue();
      } catch { return route.abort(); }
    });

    const page = await context.newPage();
    const resp = await page.goto(url, { waitUntil: 'networkidle', timeout: navTimeoutMs });

    // Redirect-escape check: the committed/final URL must still be on the allowlist.
    const finalUrl = page.url();
    const esc = assertNoRedirectEscape(finalUrl, { allowHosts, allowInsecureLocalhostTest });
    if (!esc.ok) throw new Error(`redirect_escaped:${finalUrl}`);

    // Readiness: fonts + a short settle to avoid half-loaded states.
    try { await page.evaluate(() => (document.fonts ? document.fonts.ready : null)); } catch {}
    await page.waitForTimeout(600);

    const pageTitle = await page.title().catch(() => null);
    const buffer = await page.screenshot({ fullPage: captureType === 'FULL_PAGE', type: 'png' });
    const dims = pngDimensions(buffer);
    const assetHash = createHash('sha256').update(buffer).digest('hex');
    const capturedAt = new Date().toISOString();
    const canonicalUrl = finalUrl;
    const route = (() => { try { return new URL(finalUrl).pathname || '/'; } catch { return '/'; } })();
    const domain = (() => { try { return new URL(finalUrl).hostname.toLowerCase(); } catch { return null; } })();

    const provenance = {
      tenant_id: tenantId || null,
      source_url: url,
      canonical_url: canonicalUrl,
      route,
      domain,
      captured_at: capturedAt,
      capture_method: 'playwright_chromium_headless',
      runtime: `playwright/${pw.version ?? 'unknown'} chromium ${browser.version?.() ?? ''}`.trim(),
      viewport_width: vp.width,
      viewport_height: vp.height,
      capture_type: captureType,
      asset_hash: assetHash,
      mime_type: 'image/png',
      width: dims.width,
      height: dims.height,
      page_title: pageTitle,
      http_status: resp ? resp.status() : null,
      // NOTE: no cookies/tokens/passwords/headers are ever recorded here.
    };

    const date = capturedAt.slice(0, 10);
    const storagePath = `website-captures/${tenantId || 'unknown'}/${date}/${assetHash}.png`;

    return { buffer, provenance, storagePath, bucketPath: `pulse-generated-media/${storagePath}` };
  } finally {
    await browser.close();
  }
}

// Build the exact fn_website_capture_register RPC argument object from a capture.
export function toRegisterParams(cap, { tenantId }) {
  const p = cap.provenance;
  return {
    p_tenant: tenantId,
    p_source_url: p.source_url,
    p_canonical_url: p.canonical_url,
    p_route: p.route,
    p_capture_type: p.capture_type,
    p_viewport_w: p.viewport_width,
    p_viewport_h: p.viewport_height,
    p_storage_ref: cap.bucketPath,
    p_width: p.width,
    p_height: p.height,
    p_mime: 'image/png',
    p_asset_hash: p.asset_hash,
    p_provenance: p,
  };
}

// Robust, cross-platform "is this module the entry script?" check.
//
// The naive `import.meta.url === `file://${process.argv[1]}`` comparison breaks on
// Windows: process.argv[1] is a drive path (e.g. C:\Users\...\capture.mjs) that does
// NOT stringify into a valid, normalized file URL — Node reports import.meta.url as
// `file:///C:/Users/.../capture.mjs` (three slashes, forward slashes, percent-encoded),
// so the manual-concat form never matches and the CLI block silently never runs
// (exit 0, no output, no PNG). pathToFileURL encodes the path correctly on every
// platform (POSIX and Windows alike), so this comparison is portable.
export function isMainModule(moduleUrl = import.meta.url, scriptPath = process.argv[1]) {
  if (!scriptPath) return false;
  try {
    return moduleUrl === pathToFileURL(scriptPath).href;
  } catch {
    return false;
  }
}

// CLI
if (isMainModule()) {
  const args = Object.fromEntries(
    process.argv.slice(2).reduce((acc, a, i, arr) => {
      if (a.startsWith('--')) acc.push([a.slice(2), arr[i + 1] && !arr[i + 1].startsWith('--') ? arr[i + 1] : 'true']);
      return acc;
    }, []),
  );
  const out = args.out || './out';
  mkdirSync(out, { recursive: true });
  capture({
    url: args.url,
    captureType: args.type || 'VIEWPORT',
    device: args.device || 'desktop',
    viewport: args.w && args.h ? { width: +args.w, height: +args.h, isMobile: args.device === 'mobile', deviceScaleFactor: args.device === 'mobile' ? 3 : 1 } : undefined,
    tenantId: args.tenant,
  }).then((cap) => {
    const base = join(out, `${cap.provenance.capture_type}_${cap.provenance.viewport_width}x${cap.provenance.viewport_height}_${cap.provenance.asset_hash.slice(0, 12)}`);
    writeFileSync(`${base}.png`, cap.buffer);
    writeFileSync(`${base}.provenance.json`, JSON.stringify(cap.provenance, null, 2));
    console.log(JSON.stringify({ ok: true, png: `${base}.png`, storagePath: cap.storagePath, provenance: cap.provenance }, null, 2));
  }).catch((e) => { console.error(JSON.stringify({ ok: false, error: String(e.message || e) })); process.exit(1); });
}
