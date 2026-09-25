// STRATELOQ — Creative Image Executor (server-side orchestrator)
// ----------------------------------------------------------------------------
// Generic automated static-image executor for Creative Studio. Triggered
// server-to-server after a STATIC image job reaches GENERATING (the bridge posts
// {job_id} here via pg_net). It:
//   1. resolves + idempotently CLAIMS the job (fn_media_image_execution_context) —
//      duplicate triggers/refresh/retry cannot cause a second paid OpenAI call,
//   2. asks the n8n "Creative Image Executor" webhook to run the OpenAI gpt-image-1
//      product-preserving edit (the OpenAI credential lives ONLY in n8n; never here
//      or in the browser),
//   3. uploads the generated PNG to the private pulse-generated-media bucket,
//   4. calls fn_media_complete_image_real -> GENERATED_REVIEW_REQUIRED,
//   5. on any real failure marks the job FAILED (never left GENERATING; never faked).
//
// Secrets (service-role key, n8n secret) are read ONLY from the Edge environment.
// The browser never calls n8n and never receives service-role.
//
// Cost control: at most ONE OpenAI call per job (idempotent claim). Hard cap
// CREATIVE_IMAGE_MAX_COST_USD (default 0.05) — a returned cost above the cap is
// recorded but flagged; no automatic retry/second paid call.

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const N8N_WEBHOOK =
  Deno.env.get("N8N_CREATIVE_IMAGE_WEBHOOK") ??
  "https://tradingb.app.n8n.cloud/webhook/pulse-creative-image";
const N8N_SECRET = Deno.env.get("N8N_CREATIVE_IMAGE_SECRET") ?? Deno.env.get("PULSE_DISCOVERY_WEBHOOK_SECRET") ?? "";
const GENERATED_BUCKET = Deno.env.get("PULSE_GENERATED_BUCKET") ?? "pulse-generated-media";
const MAX_COST = Number(Deno.env.get("CREATIVE_IMAGE_MAX_COST_USD") ?? "0.05");

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
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

// OpenAI gpt-image-1 usage -> USD (same basis as the prior proven workflow).
function costFromUsage(usage: Record<string, unknown> | undefined): number {
  const u = usage ?? {};
  const d = (u["input_tokens_details"] as Record<string, number> | undefined) ?? {};
  const textTok = Number(d["text_tokens"] ?? 0);
  const imgTok = Number(d["image_tokens"] ?? 0);
  const outTok = Number((u as Record<string, number>)["output_tokens"] ?? 0);
  const cost = (textTok / 1e6) * 5 + (imgTok / 1e6) * 10 + (outTok / 1e6) * 40;
  return Math.round(cost * 100000) / 100000;
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method !== "POST") return json(405, { ok: false, error: "method_not_allowed" });
  if (!SUPABASE_URL || !SERVICE_ROLE) return json(500, { ok: false, error: "server_not_configured" });

  let jobId = "";
  try { jobId = String(((await req.json()) as { job_id?: string })?.job_id || ""); }
  catch { return json(400, { ok: false, error: "invalid_json" }); }
  if (!jobId) return json(400, { ok: false, error: "job_id_required" });

  // 1) resolve + idempotent claim
  let ctx: Record<string, unknown>;
  try { ctx = (await rpc("fn_media_image_execution_context", { p_job_id: jobId })) as Record<string, unknown>; }
  catch (e) { return json(502, { ok: false, error: "context_failed", detail: (e as Error).message }); }
  if (ctx?.execute !== true) return json(200, { ok: true, skipped: true, reason: ctx?.reason ?? "not_executable" });

  const tenant = String(ctx.tenant_id);
  const productId = ctx.product_id ? String(ctx.product_id) : null;
  const market = ctx.market ? String(ctx.market) : null;

  const fail = async (reason: string) => {
    try { await rpc("fn_media_fail_image_job", { p_job_id: jobId, p_tenant: tenant, p_reason: reason }); } catch { /* best-effort */ }
  };

  // 2) OpenAI generation via the n8n proxy (credential lives only in n8n)
  let gen: Record<string, unknown>;
  try {
    const res = await fetch(N8N_WEBHOOK, {
      method: "POST",
      headers: { "content-type": "application/json", ...(N8N_SECRET ? { "x-pulse-webhook-secret": N8N_SECRET } : {}) },
      body: JSON.stringify({ job_id: jobId, source_image_url: ctx.source_image_url, prompt: ctx.prompt, size: ctx.size }),
    });
    const txt = await res.text();
    try { gen = txt ? JSON.parse(txt) : {}; } catch { gen = { raw: txt }; }
    if (!res.ok) { await fail(`n8n_http_${res.status}`); return json(502, { ok: false, error: "generation_failed", stage: "n8n", status: res.status }); }
  } catch (e) { await fail(`n8n_unreachable: ${(e as Error).message}`); return json(502, { ok: false, error: "generation_unreachable" }); }

  // n8n returns the raw OpenAI images/edits response OR {ok:false,error}
  const data0 = ((gen?.data as Array<Record<string, unknown>> | undefined) ?? [])[0] ?? {};
  const b64 = String((data0?.b64_json as string) || (gen?.b64_json as string) || "");
  if (!b64) { await fail("no_image_returned"); return json(502, { ok: false, error: "no_image_returned", detail: JSON.stringify(gen).slice(0, 300) }); }

  const usage = (gen?.usage as Record<string, unknown>) ?? undefined;
  const cost = costFromUsage(usage);
  const overCap = cost > MAX_COST;

  // 3) upload to private bucket (service-role)
  const path = String(ctx.storage_path);
  try {
    const bytes = b64ToBytes(b64);
    const up = await fetch(`${SUPABASE_URL}/storage/v1/object/${GENERATED_BUCKET}/${path}`, {
      method: "POST",
      headers: { authorization: `Bearer ${SERVICE_ROLE}`, apikey: SERVICE_ROLE, "content-type": "image/png", "x-upsert": "true" },
      body: bytes,
    });
    if (!up.ok) { const t = await up.text(); await fail(`upload_${up.status}`); return json(502, { ok: false, error: "upload_failed", detail: t.slice(0, 200) }); }
  } catch (e) { await fail(`upload_error: ${(e as Error).message}`); return json(502, { ok: false, error: "upload_error" }); }

  // 4) complete (real) -> GENERATED_REVIEW_REQUIRED
  let sizeParts = String(ctx.size || "1024x1024").split("x");
  const width = Number(sizeParts[0] || 1024), height = Number(sizeParts[1] || 1024);
  try {
    const done = (await rpc("fn_media_complete_image_real", {
      p_job_id: jobId, p_tenant: tenant, p_provider: "OPENAI_GPT_IMAGE",
      p_provider_job_id: `openai-gpt-image-1-${jobId}`, p_storage_ref: `${GENERATED_BUCKET}/${path}`,
      p_mime: "image/png", p_width: width, p_height: height, p_actual_cost: cost, p_cost_currency: "USD",
      p_product_id: productId, p_country_code: market, p_source_asset_refs: ctx.source_asset_id ? [String(ctx.source_asset_id)] : [],
      p_prompt: String(ctx.prompt || ""),
      p_provenance: { creative_format: ctx.creative_format, source_image_url: ctx.source_image_url, executor: "creative-image-execute", usage, cost_over_cap: overCap },
    })) as Record<string, unknown>;
    return json(200, { ok: true, job_id: jobId, asset_id: done?.asset_id, status: done?.status, cost_usd: cost, cost_over_cap: overCap });
  } catch (e) { await fail(`complete_error: ${(e as Error).message}`); return json(502, { ok: false, error: "complete_failed", detail: (e as Error).message }); }
});
