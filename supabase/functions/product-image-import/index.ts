// STRATELOQ — Product Image Import (customer-owned authoritative fallback)
// ----------------------------------------------------------------------------
// When Strateloq cannot obtain a lawful authoritative product image, the customer
// imports their own from the Strateloq Workspace. This edge:
//   1. authenticates the caller via their Supabase JWT (verify_jwt=true) and resolves
//      the tenant (auth user id) — the browser never receives the service-role key,
//   2. validates rights confirmation, mime type and file size,
//   3. uploads the bytes to the PRIVATE pulse-product-imports bucket (service role),
//   4. mints a durable signed URL so the existing creative/storefront pipelines can
//      fetch the source image,
//   5. registers the asset via fn_product_image_import_register, which enforces product
//      ownership and marks it rights-confirmed CUSTOMER_OWNED / CUSTOMER_UPLOAD.
//
// The register RPC (not this edge) is the authority: it re-checks tenant vs product
// ownership, so a forged product_id cannot attach an image to another tenant's product.
// Marketplace/reference images are never created here; only customer-owned imports.

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const ANON = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const BUCKET = "pulse-product-imports";
const MAX_BYTES = 15 * 1024 * 1024;
const SIGNED_URL_TTL = 315360000; // ~10 years: durable retrievable source for the pipelines
const ALLOWED = new Set(["image/png", "image/jpeg", "image/webp"]);
const EXT: Record<string, string> = { "image/png": "png", "image/jpeg": "jpg", "image/webp": "webp" };

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } });
}

async function rpc(fn: string, args: Record<string, unknown>): Promise<unknown> {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
    method: "POST",
    headers: { "content-type": "application/json", apikey: SERVICE_ROLE, authorization: `Bearer ${SERVICE_ROLE}` },
    body: JSON.stringify(args),
  });
  const txt = await res.text();
  let parsed: unknown = null;
  try { parsed = txt ? JSON.parse(txt) : null; } catch { parsed = txt; }
  if (!res.ok) throw new Error(`rpc ${fn} ${res.status}: ${String(txt).slice(0, 300)}`);
  return parsed;
}

function b64ToBytes(b64: string): Uint8Array {
  const clean = b64.includes(",") ? b64.slice(b64.indexOf(",") + 1) : b64; // tolerate data: URLs
  const bin = atob(clean);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method !== "POST") return json(405, { ok: false, error: "method_not_allowed" });
  if (!SUPABASE_URL || !SERVICE_ROLE) return json(500, { ok: false, error: "server_not_configured" });

  // 1) authenticate the caller (their JWT), resolve tenant
  const authHeader = req.headers.get("authorization") ?? "";
  if (!authHeader.toLowerCase().startsWith("bearer ")) return json(401, { ok: false, error: "missing_bearer" });
  let tenant = "";
  try {
    const u = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
      headers: { authorization: authHeader, apikey: ANON || SERVICE_ROLE },
    });
    if (!u.ok) return json(401, { ok: false, error: "invalid_token" });
    const user = await u.json() as { id?: string };
    tenant = String(user?.id || "");
  } catch { return json(401, { ok: false, error: "auth_lookup_failed" }); }
  if (!tenant) return json(401, { ok: false, error: "no_tenant" });

  // 2) parse + validate input
  let body: Record<string, unknown>;
  try { body = (await req.json()) as Record<string, unknown>; }
  catch { return json(400, { ok: false, error: "invalid_json" }); }

  const productId = String(body.product_id || "").trim();
  const market = body.market ? String(body.market).trim() : null;
  const mime = String(body.mime || "").trim().toLowerCase();
  const filename = body.filename ? String(body.filename).slice(0, 200) : null;
  const rightsConfirmed = body.rights_confirmed === true || String(body.rights_confirmed) === "true";
  const dataB64 = String(body.data_base64 || body.data || "");

  if (!productId) return json(400, { ok: false, error: "product_id_required" });
  if (!rightsConfirmed) return json(400, { ok: false, error: "rights_confirmation_required",
    message: "I confirm that I own this image or have permission to use it for this product and advertising." });
  if (!ALLOWED.has(mime)) return json(415, { ok: false, error: "unsupported_mime", allowed: [...ALLOWED] });
  if (!dataB64) return json(400, { ok: false, error: "no_file_data" });

  let bytes: Uint8Array;
  try { bytes = b64ToBytes(dataB64); } catch { return json(400, { ok: false, error: "invalid_base64" }); }
  if (bytes.length === 0) return json(400, { ok: false, error: "empty_file" });
  if (bytes.length > MAX_BYTES) return json(413, { ok: false, error: "file_too_large", max_bytes: MAX_BYTES });

  // 3) upload to the private bucket (service role); path is tenant/product-scoped
  const objId = crypto.randomUUID();
  const path = `${tenant}/${productId}/${objId}.${EXT[mime]}`;
  try {
    const up = await fetch(`${SUPABASE_URL}/storage/v1/object/${BUCKET}/${path}`, {
      method: "POST",
      headers: { authorization: `Bearer ${SERVICE_ROLE}`, apikey: SERVICE_ROLE, "content-type": mime, "x-upsert": "true" },
      body: bytes,
    });
    if (!up.ok) { const t = await up.text(); return json(502, { ok: false, error: "upload_failed", detail: t.slice(0, 200) }); }
  } catch (e) { return json(502, { ok: false, error: "upload_error", detail: (e as Error).message }); }

  // 4) mint a durable signed URL for the pipelines to fetch
  let displayUrl = "";
  try {
    const s = await fetch(`${SUPABASE_URL}/storage/v1/object/sign/${BUCKET}/${path}`, {
      method: "POST",
      headers: { authorization: `Bearer ${SERVICE_ROLE}`, apikey: SERVICE_ROLE, "content-type": "application/json" },
      body: JSON.stringify({ expiresIn: SIGNED_URL_TTL }),
    });
    if (!s.ok) { const t = await s.text(); return json(502, { ok: false, error: "sign_failed", detail: t.slice(0, 200) }); }
    const signed = await s.json() as { signedURL?: string; signedUrl?: string };
    const rel = String(signed.signedURL || signed.signedUrl || "");
    if (!rel) return json(502, { ok: false, error: "sign_empty" });
    displayUrl = rel.startsWith("http") ? rel : `${SUPABASE_URL}/storage/v1${rel.startsWith("/") ? "" : "/"}${rel}`;
  } catch (e) { return json(502, { ok: false, error: "sign_error", detail: (e as Error).message }); }

  // 5) register the asset (RPC re-verifies tenant vs product ownership + rights)
  try {
    const reg = (await rpc("fn_product_image_import_register", {
      p_tenant: tenant, p_product_id: productId, p_storage_ref: `${BUCKET}/${path}`, p_display_url: displayUrl,
      p_mime: mime, p_market: market, p_rights_confirmed: true, p_original_filename: filename,
      p_byte_size: bytes.length,
      p_provenance: { source: "CUSTOMER_UPLOAD", via: "product-image-import", object_id: objId },
    })) as Record<string, unknown>;
    if (reg?.status === "error") return json(400, { ok: false, error: reg?.error, detail: reg });
    return json(200, { ok: true, status: reg?.status, asset_id: reg?.asset_id, is_primary: reg?.is_primary,
      rights_state: "CUSTOMER_OWNED", authoritative_count: (reg?.authority as Record<string, unknown>)?.["authoritative_count"],
      authority: reg?.authority });
  } catch (e) { return json(502, { ok: false, error: "register_failed", detail: (e as Error).message }); }
});
