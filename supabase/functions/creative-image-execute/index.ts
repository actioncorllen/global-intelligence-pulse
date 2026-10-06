// STRATELOQ — Creative Image Executor (server-side orchestrator)
// Generic automated static-image executor for Creative Studio. Triggered server-to-server
// after a STATIC image job reaches GENERATING. Resolves+claims the job, runs the OpenAI
// gpt-image-1 edit via the n8n proxy (OpenAI credential lives only in n8n), uploads the PNG
// to pulse-generated-media, and calls fn_media_complete_image_real. Real failures mark the job
// FAILED (never left GENERATING; never faked). Secrets read only from the Edge environment.
//
// Integrity #4 (observability): every failure records a STRUCTURED, sanitized provider error on
// the job (provider / stage / provider_error_code / provider_error_type / provider_error_param /
// provider_error_message) via the fn_media_fail_image_job(uuid,uuid,text,jsonb) overload, in
// addition to the short error_state. No credentials, secrets or raw payloads are persisted or
// returned to the caller. The customer-facing UI stays simple; diagnostics live on the job.

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

function costFromUsage(usage: Record<string, unknown> | undefined): number {
  const u = usage ?? {};
  const d = (u["input_tokens_details"] as Record<string, number> | undefined) ?? {};
  const textTok = Number(d["text_tokens"] ?? 0);
  const imgTok = Number(d["image_tokens"] ?? 0);
  const outTok = Number((u as Record<string, number>)["output_tokens"] ?? 0);
  const cost = (textTok / 1e6) * 5 + (imgTok / 1e6) * 10 + (outTok / 1e6) * 40;
  return Math.round(cost * 100000) / 100000;
}

const s = (v: unknown, n = 500): string => String(v ?? "").slice(0, n);

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method !== "POST") return json(405, { ok: false, error: "method_not_allowed" });
  if (!SUPABASE_URL || !SERVICE_ROLE) return json(500, { ok: false, error: "server_not_configured" });

  let jobId = "";
  try { jobId = String(((await req.json()) as { job_id?: string })?.job_id || ""); }
  catch { return json(400, { ok: false, error: "invalid_json" }); }
  if (!jobId) return json(400, { ok: false, error: "job_id_required" });

  let ctx: Record<string, unknown>;
  try { ctx = (await rpc("fn_media_image_execution_context", { p_job_id: jobId })) as Record<string, unknown>; }
  catch (e) { return json(502, { ok: false, error: "context_failed", detail: (e as Error).message }); }
  if (ctx?.execute !== true) return json(200, { ok: true, skipped: true, reason: ctx?.reason ?? "not_executable" });

  const tenant = String(ctx.tenant_id);
  const productId = ctx.product_id ? String(ctx.product_id) : null;
  const market = ctx.market ? String(ctx.market) : null;

  // Mark the job FAILED with a SHORT error_state plus a STRUCTURED, sanitized provider error.
  const fail = async (reason: string, providerError?: Record<string, unknown>) => {
    try {
      await rpc("fn_media_fail_image_job", {
        p_job_id: jobId, p_tenant: tenant, p_reason: reason,
        p_provider_error: providerError ?? null,
      });
    } catch { /* best-effort */ }
  };

  let gen: Record<string, unknown>;
  try {
    const res = await fetch(N8N_WEBHOOK, {
      method: "POST",
      headers: { "content-type": "application/json", ...(N8N_SECRET ? { "x-pulse-webhook-secret": N8N_SECRET } : {}) },
      body: JSON.stringify({ job_id: jobId, source_image_url: ctx.source_image_url, prompt: ctx.prompt, size: ctx.size }),
    });
    const txt = await res.text();
    try { gen = txt ? JSON.parse(txt) : {}; } catch { gen = { raw: txt }; }
    if (!res.ok) {
      await fail(`n8n_http_${res.status}`, { provider: "N8N_PROXY", stage: "dispatch", provider_error_code: String(res.status) });
      return json(502, { ok: false, error: "generation_failed", stage: "n8n", status: res.status });
    }
  } catch (e) {
    await fail("n8n_unreachable", { provider: "N8N_PROXY", stage: "dispatch", provider_error_message: s((e as Error).message) });
    return json(502, { ok: false, error: "generation_unreachable" });
  }

  const data0 = ((gen?.data as Array<Record<string, unknown>> | undefined) ?? [])[0] ?? {};
  const b64 = String((data0?.b64_json as string) || (gen?.b64_json as string) || "");
  if (!b64) {
    // The provider (OpenAI gpt-image-1) returned no image. Capture its structured error so the
    // real cause (e.g. unsupported_file_mimetype) is retained on the job, not collapsed away.
    const e = (gen?.error ?? {}) as Record<string, unknown>;
    await fail("no_image_returned", {
      provider: "OPENAI_GPT_IMAGE",
      stage: "provider_image_edit",
      provider_error_code: s(e?.code, 120),
      provider_error_type: s(e?.type, 120),
      provider_error_param: s(e?.param, 120),
      provider_error_message: s(e?.message, 500),
    });
    return json(502, { ok: false, error: "no_image_returned", provider_error_code: s(e?.code, 120) });
  }

  const usage = (gen?.usage as Record<string, unknown>) ?? undefined;
  const cost = costFromUsage(usage);
  const overCap = cost > MAX_COST;

  const path = String(ctx.storage_path);
  try {
    const bytes = b64ToBytes(b64);
    const up = await fetch(`${SUPABASE_URL}/storage/v1/object/${GENERATED_BUCKET}/${path}`, {
      method: "POST",
      headers: { authorization: `Bearer ${SERVICE_ROLE}`, apikey: SERVICE_ROLE, "content-type": "image/png", "x-upsert": "true" },
      body: bytes,
    });
    if (!up.ok) {
      const t = await up.text();
      await fail(`upload_${up.status}`, { provider: "SUPABASE_STORAGE", stage: "upload", provider_error_code: String(up.status), provider_error_message: s(t, 500) });
      return json(502, { ok: false, error: "upload_failed", detail: t.slice(0, 200) });
    }
  } catch (e) {
    await fail("upload_error", { provider: "SUPABASE_STORAGE", stage: "upload", provider_error_message: s((e as Error).message) });
    return json(502, { ok: false, error: "upload_error" });
  }

  const sizeParts = String(ctx.size || "1024x1024").split("x");
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
  } catch (e) {
    await fail("complete_error", { provider: "DB", stage: "finalize", provider_error_message: s((e as Error).message) });
    return json(502, { ok: false, error: "complete_failed", detail: (e as Error).message });
  }
});
