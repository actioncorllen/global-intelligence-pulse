// STRATELOQ — Product Media Verify (CS.02 real dimension + URL-accessibility check).
// BE345 PREPARED ARTIFACT — committed, NOT deployed. Companion migration:
// supabase/migrations/mig_381_be345_product_image_metadata.sql.
//
// CS.02's fn_product_media_discovery already surfaces each candidate's resolution from
// provenance.width/height, but stored supplier/marketplace assets carry no dimensions,
// so it returns UNKNOWN. This edge measures the REAL dimensions + URL accessibility of a
// product's own stored image assets (a free, ranged GET of each public CDN URL from the
// edge network — NOT a paid provider API call), then records them via
// fn_record_product_image_metadata, after which discovery reports real resolutions.
//
// METADATA ONLY — fail-closed rights: measuring or reaching an image NEVER changes its
// rights_state and NEVER grants research/AI-input/commercial use. CS.02's permission
// classification (fn_asset_use_eligibility) is untouched; a supplier/marketplace image
// stays research/identity-only regardless of how large or reachable it is.
//
// Why an edge (not this repo's CI): the agent proxy blocks supplier CDNs
// (cf.cjdropshipping.com etc. -> 403); only the deployed edge network reaches them.

import { parseImageDimensions } from "./image-dimensions.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const MAX_ASSETS = Number(Deno.env.get("PULSE_MEDIA_VERIFY_MAX") ?? "40");
const RANGE_BYTES = 131071; // first 128 KB is enough for a header

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "content-type": "application/json", "cache-control": "no-store" },
  });
}
async function rpc(fn: string, args: Record<string, unknown>): Promise<unknown> {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
    method: "POST",
    headers: { "content-type": "application/json", apikey: SERVICE_ROLE, authorization: `Bearer ${SERVICE_ROLE}` },
    body: JSON.stringify(args),
  });
  const txt = await res.text();
  if (!res.ok) throw new Error(`rpc ${fn} ${res.status}: ${String(txt).slice(0, 200)}`);
  return txt ? JSON.parse(txt) : null;
}

/** Measure one asset URL: ranged GET, real dimensions, http status, content type/length. */
export async function probeImage(
  url: string,
): Promise<{ httpStatus: number | null; contentType: string | null; byteSize: number | null; width: number | null; height: number | null; format: string | null; error?: string }> {
  try {
    const res = await fetch(url, {
      method: "GET",
      headers: { "User-Agent": "pulse-media-verify/1.0", Range: `bytes=0-${RANGE_BYTES}` },
      signal: AbortSignal.timeout(20000),
    });
    const contentType = res.headers.get("content-type");
    const lenHeader = res.headers.get("content-range") ?? res.headers.get("content-length");
    const byteSize = lenHeader ? Number((lenHeader.split("/")[1] ?? lenHeader).replace(/[^0-9]/g, "")) || null : null;
    if (!res.ok && res.status !== 206) {
      try { await res.body?.cancel(); } catch { /* ignore */ }
      return { httpStatus: res.status, contentType, byteSize, width: null, height: null, format: null };
    }
    const buf = new Uint8Array(await res.arrayBuffer());
    const dims = parseImageDimensions(buf);
    return {
      httpStatus: res.status,
      contentType,
      byteSize,
      width: dims?.width ?? null,
      height: dims?.height ?? null,
      format: dims?.format ?? null,
    };
  } catch (e) {
    return { httpStatus: null, contentType: null, byteSize: null, width: null, height: null, format: null, error: (e as Error).message };
  }
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") return new Response("ok", { status: 200, headers: CORS_HEADERS });
  if (req.method !== "POST") return json(405, { status: "METHOD_NOT_ALLOWED" });
  if (!SUPABASE_URL || !SERVICE_ROLE) return json(500, { status: "SERVER_NOT_CONFIGURED" });

  const authHeader = req.headers.get("Authorization") ?? "";
  if (!/^Bearer\s+.+/i.test(authHeader)) return json(401, { status: "UNAUTHENTICATED" });
  let userId = "";
  try {
    const u = await fetch(`${SUPABASE_URL}/auth/v1/user`, { headers: { apikey: SERVICE_ROLE, authorization: authHeader } });
    if (!u.ok) return json(401, { status: "UNAUTHENTICATED" });
    userId = String((await u.json())?.id ?? "");
  } catch { return json(401, { status: "UNAUTHENTICATED" }); }
  if (!userId) return json(401, { status: "UNAUTHENTICATED" });

  let body: Record<string, unknown>;
  try { body = (await req.json()) as Record<string, unknown>; } catch { return json(400, { status: "INVALID_JSON" }); }
  const productId = String(body.product_id ?? "");
  if (!/^[0-9a-f-]{36}$/i.test(productId)) return json(400, { status: "INVALID_PRODUCT" });

  // Owner-scoped: only the owning tenant's own product + its own assets.
  let product: Record<string, unknown> | null = null;
  try {
    const pr = await fetch(`${SUPABASE_URL}/rest/v1/commerce_products?id=eq.${productId}&select=id,user_id`, {
      headers: { apikey: SERVICE_ROLE, authorization: `Bearer ${SERVICE_ROLE}` },
    });
    const arr = await pr.json();
    product = Array.isArray(arr) ? arr[0] ?? null : null;
  } catch { /* fallthrough */ }
  if (!product) return json(404, { status: "PRODUCT_NOT_FOUND" });
  if (String(product.user_id) !== userId) return json(403, { status: "CROSS_TENANT_REJECTED" });

  let assets: Array<Record<string, unknown>> = [];
  try {
    const r = await fetch(
      `${SUPABASE_URL}/rest/v1/product_image_assets?product_id=eq.${productId}&tenant_id=eq.${userId}&is_fixture=eq.false&select=id,image_url,source_url&limit=${MAX_ASSETS}`,
      { headers: { apikey: SERVICE_ROLE, authorization: `Bearer ${SERVICE_ROLE}` } },
    );
    const arr = await r.json();
    assets = Array.isArray(arr) ? arr : [];
  } catch { return json(200, { status: "NO_ASSETS", verified: 0 }); }

  let verified = 0, reachable = 0, measured = 0;
  const results: Array<Record<string, unknown>> = [];
  for (const a of assets) {
    const url = String(a.image_url ?? a.source_url ?? "");
    if (!/^https?:\/\//i.test(url)) continue;
    const p = await probeImage(url);
    const accessible = p.httpStatus === 200 || p.httpStatus === 206;
    if (accessible) reachable++;
    if (p.width && p.height) measured++;
    try {
      await rpc("fn_record_product_image_metadata", {
        p_asset_id: a.id,
        p_tenant: userId,
        p_width: p.width,
        p_height: p.height,
        p_http_status: p.httpStatus,
        p_content_type: p.contentType,
        p_byte_size: p.byteSize,
      });
      verified++;
    } catch (e) {
      results.push({ asset_id: a.id, record_error: (e as Error).message });
      continue;
    }
    results.push({ asset_id: a.id, http_status: p.httpStatus, accessible, width: p.width, height: p.height, format: p.format });
  }

  return json(200, {
    status: "VERIFIED",
    product_id: productId,
    assets_considered: assets.length,
    recorded: verified,
    reachable,
    measured,
    note: "Metadata only — dimensions + accessibility recorded; rights_state and permitted use are unchanged. Supplier/marketplace images remain research/identity-only.",
    results,
  });
});
