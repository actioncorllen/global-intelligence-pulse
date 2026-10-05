// Website Asset Capture — URL / SSRF validation (pure, unit-testable).
// STRATELOQ-WEBSITE-ASSET-CAPTURE-001. Public routes only.
//
// This is the worker-side guard. The database RPC (fn__wac_host_allowed) enforces
// the same domain allowlist as defense-in-depth.

export const DEFAULT_ALLOW_HOSTS = [
  'globalintelligenceactions.com',
  'www.globalintelligenceactions.com',
];

// Hostnames that must never be reached (metadata / loopback / internal).
const BLOCKED_HOST_LITERALS = new Set([
  'localhost', 'ip6-localhost', 'metadata', 'metadata.google.internal',
]);

function isPrivateOrReservedIp(host) {
  // IPv4 literal?
  const m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(host);
  if (m) {
    const o = m.slice(1).map(Number);
    if (o.some((n) => n > 255)) return true; // malformed => reject
    const [a, b] = o;
    if (a === 10) return true;                         // 10.0.0.0/8
    if (a === 127) return true;                        // loopback
    if (a === 0) return true;                          // 0.0.0.0/8
    if (a === 169 && b === 254) return true;           // link-local incl. 169.254.169.254 metadata
    if (a === 172 && b >= 16 && b <= 31) return true;  // 172.16.0.0/12
    if (a === 192 && b === 168) return true;           // 192.168.0.0/16
    if (a === 100 && b >= 64 && b <= 127) return true; // CGNAT 100.64.0.0/10
    if (a >= 224) return true;                         // multicast / reserved
    return false;
  }
  // IPv6 loopback / link-local / unique-local
  if (host.includes(':')) {
    const h = host.replace(/^\[|\]$/g, '').toLowerCase();
    if (h === '::1' || h === '::') return true;
    if (h.startsWith('fe80') || h.startsWith('fc') || h.startsWith('fd')) return true;
    return true; // any other raw IPv6 literal: reject by default for public capture
  }
  return false;
}

// Validate a candidate capture URL against the allowlist + SSRF rules.
// Returns { ok, host, canonicalUrl, reason }.
export function validateCaptureUrl(rawUrl, opts = {}) {
  const allow = (opts.allowHosts || DEFAULT_ALLOW_HOSTS).map((h) => h.toLowerCase());
  const allowInsecureLocalhostTest = opts.allowInsecureLocalhostTest === true; // TEST-ONLY

  let u;
  try { u = new URL(rawUrl); } catch { return { ok: false, reason: 'unparseable_url' }; }

  // TEST-ONLY escape hatch to prove the headless renderer against a local fixture.
  // Never enabled in production capture.
  if (allowInsecureLocalhostTest && (u.protocol === 'http:' || u.protocol === 'https:')
      && (u.hostname === '127.0.0.1' || u.hostname === 'localhost')) {
    return { ok: true, host: u.hostname, canonicalUrl: u.toString(), test: true };
  }

  if (u.protocol !== 'https:') return { ok: false, reason: 'scheme_not_https', scheme: u.protocol };
  if (u.username || u.password) return { ok: false, reason: 'userinfo_not_allowed' };
  const host = u.hostname.toLowerCase();
  if (BLOCKED_HOST_LITERALS.has(host)) return { ok: false, reason: 'blocked_host_literal', host };
  if (isPrivateOrReservedIp(host)) return { ok: false, reason: 'private_or_reserved_ip', host };
  if (!allow.includes(host)) return { ok: false, reason: 'host_not_on_allowlist', host };

  return { ok: true, host, canonicalUrl: u.toString() };
}

// Re-check a post-redirect/final URL: it must still satisfy the allowlist,
// otherwise the navigation escaped the approved domain.
export function assertNoRedirectEscape(finalUrl, opts = {}) {
  const r = validateCaptureUrl(finalUrl, opts);
  if (!r.ok) return { ok: false, reason: 'redirect_escaped_allowlist', finalUrl, detail: r.reason };
  return { ok: true, host: r.host };
}
