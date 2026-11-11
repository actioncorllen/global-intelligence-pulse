// STRATELOQ-KALODATA-PRODUCT-IMAGES-BROKER (PROPOSED — NOT DEPLOYED)
// ----------------------------------------------------------------------------
// Phase 13 draft. Multi-image research gallery for a Kalodata product.
//
// Documented contract (official Kalodata Open API):
//   POST https://www.kalodata.com/openapi/v1/tiktok/product/images
//   Header: secret-key: <KALODATA_SECRET_KEY>
//   Request:  { "product_id": "<kalodata product id>" }
//   Response: { data: { product_id, images: string[] (SIGNED, expire in ~5 min), expires_at } }
//   Rate limit: 10 requests / 10 seconds.
//
// Because the signed image URLs expire in ~5 minutes, this edge DOWNLOADS the bytes server-side
// immediately, stores them in the PRIVATE research bucket (service role, never exposed to the browser),
// mints a durable signed URL, and registers each image as a REFERENCE_ONLY research asset via
// fn_persist_kalodata_research_image (rights_state PROVIDER_DISCOVERY_REFERENCE). Tenant-authorised
// delivery is enforced downstream by the auth.uid()+ownership display gates (fn_product_media_state /
// fn_resolve_product_image), which decide who ever receives the durable URL.
//
// Credits: the caller (fn_kalodata_run_product_images) has already reserved + authorized via the EXISTING
// discovery credit workflow and passes refresh_request_id. This edge settles SUCCESS once the provider
// returns usable data, and refunds (fn_kalodata_op_complete_from_edge) only on provider failure. Failed
// downloads / expired URLs / partial galleries fail safe: whatever cached successfully is kept; the API
// charge (for the metadata + URLs the provider returned) is legitimately consumed. Dedup on content hash.
//
// Mirrors kalodata-video-detail (auth/gate/redact/settle) + product-image-import (upload/sign). No ad /
// storefront / commercial use is ever unlocked. Not deployed; no chargeable call is made from here.

const SECRET_ENV = "KALODATA_SECRET_KEY";
const SECRET_HEADER_ENV = "KALODATA_SECRET_HEADER";
const IMAGES_BASE_ENV = "KALODATA_PRODUCT_IMAGES_BASE_URL";
const BUCKET_ENV = "KALODATA_RESEARCH_BUCKET";
const DEFAULT_ENDPOINT = "https://www.kalodata.com/openapi/v1/tiktok/product/images";
const DEFAULT_BUCKET = "pulse-research-reference";
const MAX_IMAGES = 24;
const MAX_BYTES = 15 * 1024 * 1024;        // per image
const FETCH_TIMEOUT_MS = 15000;
const DURABLE_SIGNED_TTL = 315360000;      // ~10y durable signed URL (same convention as product-image-import)
const ALLOWED_MIME: Record<string, string> = { "image/png": "png", "image/jpeg": "jpg", "image/webp": "webp" };

const SUPABASE_URL = (Deno.env.get("SUPABASE_URL") || "").replace(/\/+$/, "");
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } });
}
function redact(input: unknown): string {
  let s = typeof input === "string" ? input : JSON.stringify(input ?? "");
  const v = Deno.env.get(SECRET_ENV);
  if (v && v.length > 0) { s = s.split(v).join("[REDACTED]"); const t = v.trim(); if (t.length > 0 && t !== v) s = s.split(t).join("[REDACTED]"); }
  s = s.replace(/("?(?:secret[_-]?key|api[_-]?key|access_token|authorization)"?\s*[:=]\s*)("?[^"&,}\s]+)/gi, "$1[REDACTED]");
  return s.slice(0, 500);
}
function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length || a.length === 0) return false;
  let out = 0; for (let i = 0; i < a.length; i++) out |= a.charCodeAt(i) ^ b.charCodeAt(i); return out === 0;
}
function callerRole(req: Request): string | null {
  const m = (req.headers.get("authorization") || "").match(/^Bearer\s+(.+)$/i);
  if (!m) return null; const parts = m[1].split("."); if (parts.length < 2) return null;
  try { const b64 = parts[1].replace(/-/g, "+").replace(/_/g, "/"); const pad = b64 + "=".repeat((4 - (b64.length % 4)) % 4); return JSON.parse(atob(pad)).role ?? null; } catch { return null; }
}
function isTrustedServer(req: Request): boolean {
  const svc = SERVICE_ROLE;
  const apikey = req.headers.get("apikey") || "";
  const bearer = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
  return callerRole(req) === "service_role" || timingSafeEqual(apikey, svc) || timingSafeEqual(bearer, svc);
}
async function rpc(fn: string, args: Record<string, unknown>): Promise<{ ok: boolean; status: number; body: unknown }> {
  const url = SUPABASE_URL + "/rest/v1/rpc/" + fn;
  const r = await fetch(url, { method: "POST", headers: { "content-type": "application/json", apikey: SERVICE_ROLE, authorization: "Bearer " + SERVICE_ROLE }, body: JSON.stringify(args) });
  const body = await r.json().catch(() => ({}));
  return { ok: r.ok, status: r.status, body };
}
async function sha256Hex(data: ArrayBuffer): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", data);
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");
}
// Pull the signed-URL array + expiry out of the (possibly nested) provider envelope.
function extractImages(body: any): { images: string[]; productId: string | null; expiresAt: string | null } {
  const d = body?.data ?? body?.result ?? body ?? {};
  let arr: unknown = d?.images ?? d?.image_list ?? d?.urls ?? [];
  if (!Array.isArray(arr)) arr = [];
  const images = (arr as unknown[])
    .map((x) => (typeof x === "string" ? x : (x && typeof x === "object" ? String((x as any).url ?? (x as any).image_url ?? "") : "")))
    .map((s) => s.trim())
    .filter((s) => /^https?:\/\//i.test(s));
  return { images, productId: d?.product_id != null ? String(d.product_id) : null, expiresAt: d?.expires_at != null ? String(d.expires_at) : null };
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return jsonResponse(405, { ok: false, error: "method_not_allowed" });
  if (!SUPABASE_URL || !SERVICE_ROLE) return jsonResponse(500, { ok: false, error: "server_not_configured" });

  let trusted = isTrustedServer(req);
  if (!trusted) {
    const nonce = req.headers.get("x-pulse-nonce");
    if (nonce && nonce.length >= 32) { try { const nr = await rpc("fn_kalodata_consume_invoke_nonce", { p_token: nonce }); trusted = nr.ok && (nr.body === true || nr.body === "true"); } catch { trusted = false; } }
  }
  if (!trusted) return jsonResponse(403, { ok: false, error: "forbidden_requires_service_role_or_valid_nonce" });

  let payload: any = {};
  const raw = await req.text();
  if (raw && raw.trim().length > 0) { try { payload = JSON.parse(raw); } catch { return jsonResponse(400, { ok: false, error: "invalid_json" }); } }
  const secret = (Deno.env.get(SECRET_ENV) ?? "").trim();
  if (payload.probe === true) return jsonResponse(200, { ok: true, mode: "probe", secret_present: Boolean(secret) });

  const market = String(payload.market ?? "").trim().toUpperCase();
  const tenant = String(payload.user_id ?? payload.userId ?? "").trim();
  const productId = String(payload.product_id ?? "").trim();            // internal commerce_products uuid
  const kalodataProductId = String(payload.kalodata_product_id ?? "").trim();
  const refreshRequestId: string | null = String(payload.refresh_request_id ?? "").trim() || null;
  const bucket = (Deno.env.get(BUCKET_ENV) || DEFAULT_BUCKET).trim();

  const settle = async (outcome: string): Promise<void> => {
    if (!refreshRequestId) return;
    try { await rpc("fn_kalodata_op_complete_from_edge", { p_request_id: refreshRequestId, p_outcome: outcome }); } catch (_e) { /* reconcile sweep is the backstop */ }
  };

  if (!market) return jsonResponse(400, { ok: false, error: "missing_market" });
  if (!tenant) return jsonResponse(400, { ok: false, error: "missing_user_id" });
  if (!productId) return jsonResponse(400, { ok: false, error: "missing_product_id" });
  if (!kalodataProductId) return jsonResponse(400, { ok: false, error: "missing_kalodata_product_id" });
  if (!secret) { await settle("PROVIDER_FAILED_PRE_CHARGE"); return jsonResponse(424, { ok: false, provider: "KALODATA", market, lane_status: "AUTH_FAILED", error: "server_secret_unavailable" }); }

  // market gate via the request builder (documented body is only {product_id})
  const reqBuild = await rpc("fn_kalodata_images_request", { p_market: market, p_kalodata_product_id: kalodataProductId });
  const rb: any = reqBuild.body;
  if (!reqBuild.ok || !rb || rb.ok !== true) {
    const reason = rb?.reason ?? "request_builder_failed";
    await settle("PROVIDER_FAILED_PRE_CHARGE");
    return jsonResponse(reason === "UNSUPPORTED_MARKET" ? 200 : 502, { ok: false, provider: "KALODATA", market, lane_status: reason });
  }

  const endpoint = (Deno.env.get(IMAGES_BASE_ENV) || DEFAULT_ENDPOINT).trim();
  const secretHeader = (Deno.env.get(SECRET_HEADER_ENV) || "secret-key").trim();

  // call the provider
  let provider: Response; let providerBody: any = {};
  try {
    provider = await fetch(endpoint, { method: "POST", headers: { "content-type": "application/json", [secretHeader]: secret }, body: JSON.stringify(rb.request_body ?? { product_id: kalodataProductId }) });
    providerBody = await provider.json().catch(() => ({}));
  } catch (e) { await settle("PROVIDER_FAILED_POST_CHARGE"); return jsonResponse(502, { ok: false, provider: "KALODATA", market, lane_status: "PROVIDER_UNAVAILABLE", error: redact((e as Error).message) }); }
  if (!provider.ok) {
    const laneStatus = provider.status === 401 || provider.status === 403 ? "AUTH_FAILED" : provider.status === 402 ? "PAYMENT_REQUIRED" : provider.status === 429 ? "RATE_LIMITED" : provider.status >= 500 ? "PROVIDER_UNAVAILABLE" : "FAILED";
    await settle("PROVIDER_FAILED_POST_CHARGE");
    return jsonResponse(provider.status === 402 ? 402 : 502, { ok: false, provider: "KALODATA", market, lane_status: laneStatus, http_status: provider.status, error: redact(providerBody?.message ?? providerBody?.error ?? "provider_error") });
  }

  const { images, expiresAt } = extractImages(providerBody);
  const expiresAtMs = expiresAt ? Date.parse(expiresAt) : NaN;

  // Provider returned no imagery: the call succeeded (charge legitimate); nothing to cache.
  if (images.length === 0) {
    await settle("SUCCESS");
    return jsonResponse(200, { ok: true, provider: "KALODATA", market, lane_status: "SUCCESS_NO_IMAGES", product_id: kalodataProductId, cached: 0, rights_state: "PROVIDER_DISCOVERY_REFERENCE" });
  }

  const results: Array<{ position: number; status: string; asset_id?: string; reason?: string }> = [];
  let cached = 0, deduped = 0, failed = 0, skippedExpired = 0;
  const seenHashes = new Set<string>();  // in-batch dedup

  for (let i = 0; i < images.length && i < MAX_IMAGES; i++) {
    const src = images[i];
    try {
      // fail safe: if the provider already declared these URLs expired, do not attempt (would 403).
      if (Number.isFinite(expiresAtMs) && Date.now() >= expiresAtMs) { skippedExpired++; results.push({ position: i, status: "skipped_expired" }); continue; }

      // 1) fetch bytes before expiry
      const ctl = new AbortController();
      const timer = setTimeout(() => ctl.abort(), FETCH_TIMEOUT_MS);
      let imgRes: Response;
      try { imgRes = await fetch(src, { signal: ctl.signal }); } finally { clearTimeout(timer); }
      if (!imgRes.ok) { failed++; results.push({ position: i, status: "download_failed", reason: "http_" + imgRes.status }); continue; }
      const ct = (imgRes.headers.get("content-type") || "").split(";")[0].trim().toLowerCase();
      const mime = ALLOWED_MIME[ct] ? ct : (ct === "image/jpg" ? "image/jpeg" : "");
      if (!mime) { failed++; results.push({ position: i, status: "unsupported_mime", reason: ct || "unknown" }); continue; }
      const ab = await imgRes.arrayBuffer();
      const buf = new Uint8Array(ab);
      if (buf.length === 0) { failed++; results.push({ position: i, status: "empty" }); continue; }
      if (buf.length > MAX_BYTES) { failed++; results.push({ position: i, status: "too_large" }); continue; }

      // 2) content hash (stable dedup key)
      const hash = await sha256Hex(ab);
      if (seenHashes.has(hash)) { deduped++; results.push({ position: i, status: "deduped_in_batch" }); continue; }
      seenHashes.add(hash);

      // 3) skip the upload if this exact image is already cached for the product
      try {
        const ex = await rpc("fn_kalodata_research_image_exists", { p_tenant: tenant, p_product: productId, p_content_hash: hash });
        if (ex.ok && (ex.body === true || ex.body === "true")) { deduped++; results.push({ position: i, status: "already_cached" }); continue; }
      } catch (_e) { /* non-fatal: fall through to persist, which also dedups on content_hash */ }

      // 4) upload bytes to the PRIVATE bucket (service role; hash-addressed path => idempotent)
      const ext = ALLOWED_MIME[mime];
      const objectPath = `kalodata/${tenant}/${productId}/${hash}.${ext}`;
      const storageRef = `${bucket}/${objectPath}`;
      const up = await fetch(`${SUPABASE_URL}/storage/v1/object/${bucket}/${objectPath}`, {
        method: "POST", headers: { authorization: `Bearer ${SERVICE_ROLE}`, apikey: SERVICE_ROLE, "content-type": mime, "x-upsert": "true" }, body: buf,
      });
      if (!up.ok) { failed++; results.push({ position: i, status: "upload_failed", reason: redact(await up.text().catch(() => "")) }); continue; }

      // 5) mint a durable signed URL (only ever returned to the owner via the display gates)
      let displayUrl = "";
      const sig = await fetch(`${SUPABASE_URL}/storage/v1/object/sign/${bucket}/${objectPath}`, {
        method: "POST", headers: { authorization: `Bearer ${SERVICE_ROLE}`, apikey: SERVICE_ROLE, "content-type": "application/json" }, body: JSON.stringify({ expiresIn: DURABLE_SIGNED_TTL }),
      });
      if (!sig.ok) { failed++; results.push({ position: i, status: "sign_failed", reason: redact(await sig.text().catch(() => "")) }); continue; }
      const signed = await sig.json().catch(() => ({})) as { signedURL?: string; signedUrl?: string };
      const rel = String(signed.signedURL || signed.signedUrl || "");
      if (!rel) { failed++; results.push({ position: i, status: "sign_empty" }); continue; }
      displayUrl = rel.startsWith("http") ? rel : `${SUPABASE_URL}/storage/v1${rel.startsWith("/") ? "" : "/"}${rel}`;

      // 6) register as REFERENCE_ONLY research asset (RPC re-checks ownership + dedups on hash)
      const persist = await rpc("fn_persist_kalodata_research_image", {
        p_tenant: tenant, p_product: productId, p_market: market, p_kalodata_product_id: kalodataProductId,
        p_gallery_position: i, p_image_url: displayUrl, p_source_url: src, p_source_url_expires_at: expiresAt,
        p_storage_ref: storageRef, p_content_hash: hash, p_mime: mime,
      });
      const pb: any = persist.body;
      if (!persist.ok || !pb || (pb.status !== "registered" && pb.status !== "exists")) { failed++; results.push({ position: i, status: "persist_failed", reason: redact(pb ?? "") }); continue; }
      if (pb.status === "exists") { deduped++; results.push({ position: i, status: "deduped_db", asset_id: pb.asset_id }); }
      else { cached++; results.push({ position: i, status: "cached", asset_id: pb.asset_id }); }
    } catch (e) {
      failed++; results.push({ position: i, status: "error", reason: redact((e as Error).message) });
    }
  }

  // Provider returned usable data => the credit is legitimately consumed (settle SUCCESS), even if some or
  // all downloads failed. Nothing half-cached is ever registered (persister requires a durable copy + hash).
  await settle("SUCCESS");

  // best-effort usage accounting (mirrors the other kalodata edges)
  try {
    const lane = await rpc("fn_kalodata_record_lane_outcome", { p_user_id: tenant, p_market: market, p_lane_status: "SUCCESS_PRODUCT_IMAGES", p_detail: { operation: "tiktok/product/images", kalodata_product_id: kalodataProductId, returned: images.length, cached } });
    const runId = (lane.body as any)?.run_id ?? null;
    if (runId) await rpc("fn_kalodata_record_usage", { p_run_id: runId, p_usage: { provider: "KALODATA", operation: "tiktok/product/images", tenant_id: tenant, country: market, call_count: 1, http_status: provider.status, recorded_by: "kalodata-product-images-edge", recorded_at: new Date().toISOString() }, p_endpoint: endpoint });
  } catch (_e) { /* best-effort */ }

  return jsonResponse(200, {
    ok: true, provider: "KALODATA", market, lane_status: "SUCCESS_PRODUCT_IMAGES",
    product_id: kalodataProductId, returned: images.length,
    cached, deduped, failed, skipped_expired: skippedExpired,
    rights_state: "PROVIDER_DISCOVERY_REFERENCE", authority: "REFERENCE_ONLY",
    commercial_use: "NOT_CLEARED_REFERENCE_ONLY", results,
  });
});
