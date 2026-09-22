// STRATELOQ 015F — tenant-safe signed delivery for generated media.
// verify_jwt=true: caller must present a valid user JWT. Ownership is enforced by
// the SECURITY DEFINER RPC fn_media_asset_signed_ref (tenant_id = auth.uid), called
// WITH the caller's JWT so a tenant can never resolve another tenant's asset. The
// service-role key is used ONLY to mint a short-lived signed URL for the owned path
// and is never returned to the browser.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const BUCKET = "pulse-generated-media";
const TTL = 300; // seconds

const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { "Content-Type": "application/json" } });

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  const auth = req.headers.get("Authorization") || "";
  if (!auth.toLowerCase().startsWith("bearer ")) return json({ error: "unauthenticated" }, 401);

  let assetId = "";
  try { assetId = (await req.json())?.asset_id ?? ""; } catch { /* ignore */ }
  if (!assetId) return json({ error: "asset_id_required" }, 400);

  // 1) Ownership check as the CALLER (auth.uid enforced inside the RPC).
  const rpc = await fetch(`${SUPABASE_URL}/rest/v1/rpc/fn_media_asset_signed_ref`, {
    method: "POST",
    headers: { "Content-Type": "application/json", apikey: ANON_KEY, Authorization: auth },
    body: JSON.stringify({ p_asset_id: assetId }),
  });
  if (!rpc.ok) return json({ error: "lookup_failed" }, 502);
  const owned = await rpc.json();
  if (owned?.status !== "ok") return json({ error: owned?.status ?? "forbidden" }, 403);

  // 2) Mint a short-lived signed URL with the service role for the OWNED path only.
  const sign = await fetch(
    `${SUPABASE_URL}/storage/v1/object/sign/${BUCKET}/${owned.storage_ref}`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json", apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}` },
      body: JSON.stringify({ expiresIn: TTL }),
    },
  );
  if (!sign.ok) return json({ error: "sign_failed" }, 502);
  const signed = await sign.json();
  const path = signed?.signedURL ?? signed?.signedUrl;
  if (!path) return json({ error: "no_signed_url" }, 502);

  return json({
    status: "ok",
    signed_url: `${SUPABASE_URL}/storage/v1${path}`,
    expires_in: TTL,
    approval_state: owned.approval_state,
    is_launch_safe: owned.is_launch_safe,
    note: "private bucket; short-lived signed URL; not launch-safe until human approval",
  });
});
