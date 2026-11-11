// STRATELOQ — tenant-safe SHORT-LIVED signed delivery for cached Kalodata research images.
// (PROPOSED — NOT DEPLOYED. Phase 14 security correction.)
// ----------------------------------------------------------------------------
// A faithful reuse of the media-asset-url mechanism (same security model), for product_image_assets in
// the PRIVATE research bucket instead of media_assets in pulse-generated-media:
//
//   verify_jwt=true: the caller must present a valid user JWT. Ownership is enforced by the SECURITY
//   DEFINER RPC fn_product_image_signed_ref (tenant_id = auth.uid + product ownership), called WITH the
//   caller's JWT, so a tenant can never resolve another tenant's object. The service-role key is used
//   ONLY to mint a SHORT-LIVED (300s) signed URL for the owned object path and is never returned to the
//   browser. No long-lived / durable signed URL is ever produced or stored.
//
// Research images are REFERENCE_ONLY: the response states commercial_use=NOT_CLEARED_REFERENCE_ONLY and
// the image may never be used for ads, storefront publishing or commercial creative generation.

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const DEFAULT_BUCKET = "pulse-research-reference";
const TTL = 300; // seconds — short-lived

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (b: unknown, s = 200): Response =>
  new Response(JSON.stringify(b), {
    status: s,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json", "cache-control": "no-store" },
  });

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") return new Response("ok", { status: 200, headers: CORS_HEADERS });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  if (!SUPABASE_URL || !SERVICE_KEY) return json({ error: "server_not_configured" }, 500);
  const auth = req.headers.get("Authorization") || "";
  if (!auth.toLowerCase().startsWith("bearer ")) return json({ error: "unauthenticated" }, 401);

  let assetId = "";
  try { const b = await req.json(); assetId = String(b?.product_image_asset_id ?? b?.asset_id ?? ""); } catch { /* ignore */ }
  if (!assetId) return json({ error: "asset_id_required" }, 400);

  // 1) Ownership check as the CALLER (auth.uid enforced inside the RPC).
  const rpc = await fetch(`${SUPABASE_URL}/rest/v1/rpc/fn_product_image_signed_ref`, {
    method: "POST",
    headers: { "Content-Type": "application/json", apikey: ANON_KEY, Authorization: auth },
    body: JSON.stringify({ p_asset_id: assetId }),
  });
  if (!rpc.ok) return json({ error: "lookup_failed" }, 502);
  const owned = await rpc.json();
  if (owned?.status !== "ok") return json({ error: owned?.status ?? "forbidden" }, owned?.status === "unauthenticated" ? 401 : 403);

  // storage_ref carries the bucket prefix; the sign endpoint needs the OBJECT path only.
  const bucket = String(owned.bucket || DEFAULT_BUCKET);
  const ref = String(owned.storage_ref ?? "");
  const objectPath = ref.startsWith(`${bucket}/`) ? ref.slice(bucket.length + 1) : ref;
  if (!objectPath) return json({ error: "no_object_path" }, 502);

  // 2) Mint a SHORT-LIVED signed URL with the service role for the OWNED path only.
  const sign = await fetch(`${SUPABASE_URL}/storage/v1/object/sign/${bucket}/${objectPath}`, {
    method: "POST",
    headers: { "Content-Type": "application/json", apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}` },
    body: JSON.stringify({ expiresIn: TTL }),
  });
  if (!sign.ok) return json({ error: "sign_failed" }, 502);
  const signed = await sign.json();
  const path = signed?.signedURL ?? signed?.signedUrl;
  if (!path) return json({ error: "no_signed_url" }, 502);

  return json({
    status: "ok",
    signed_url: `${SUPABASE_URL}/storage/v1${String(path).startsWith("/") ? "" : "/"}${path}`,
    expires_in: TTL,
    rights_state: owned.rights_state ?? "PROVIDER_DISCOVERY_REFERENCE",
    authority: "REFERENCE_ONLY",
    commercial_use: "NOT_CLEARED_REFERENCE_ONLY",
    note: "private research bucket; short-lived signed URL; reference-only — never ads/storefront/commercial creative",
  });
});
