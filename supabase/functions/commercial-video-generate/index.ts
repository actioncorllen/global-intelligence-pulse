// STRATELOQ — Commercial VIDEO Generate (minimum provider executor for the EXISTING
// video-job pipeline). BE344 P3 PREPARED ARTIFACT — committed, NOT deployed, NO paid
// video call. Companion research: Gemini Omni 1.2 Flash (Gemini Developer API) is the
// evaluated provider because Veo left the Gemini Developer API (see the BE343/BE344
// reports). The provider call is delegated to an n8n workflow (as the image edge is),
// so the exact Omni Flash request schema lives in that workflow, not here.
//
// This edge is the thin wiring around ./video-executor-core.ts (the dependency-injected
// pure executor the deterministic tests cover). It REUSES the media-job lifecycle
// (fn_media_dispatch_video_job -> fn_media_complete_video_real / fn_media_retry_video_job)
// and the explicit cost-authorization gate (fn_video_generation_authorization_state),
// which is fail-closed: no paid provider call unless dispatch_allowed === true (provider
// enabled + founder authorization + within cap). The executor produces ACTUAL moving
// video (one image-to-video generation), stores it privately, and completes the asset
// IN_REVIEW / IDENTITY_REVIEW_REQUIRED / not launch-safe — never auto-cleared or published.
//
// Deploy dependencies (future controlled approval, NOT done here): register an enabled
// VIDEO provider in media_providers for the chosen surface, wire the n8n video workflow
// to the real Omni Flash (or Enterprise-Platform Veo) API, and open founder spend
// authorization so fn_video_generation_authorization_state returns dispatch_allowed=true.

import { executeVideoScene, type VideoExecutorDeps } from "./video-executor-core.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const WEBHOOK_SECRET =
  Deno.env.get("N8N_GEMINI_WEBHOOK_SECRET") ?? Deno.env.get("PULSE_DISCOVERY_WEBHOOK_SECRET") ?? "";
const VIDEO_EXECUTOR_WEBHOOK =
  Deno.env.get("N8N_GEMINI_VIDEO_EXECUTOR_WEBHOOK") ??
  "https://tradingb.app.n8n.cloud/webhook/pulse-gemini-commercial-video";
// Evaluated provider (Gemini Omni 1.2 Flash on the Gemini Developer API). Env-overridable
// so the surface/model can change (e.g. to Enterprise-Platform Veo) without a code change.
const PROVIDER_ID = Deno.env.get("PULSE_VIDEO_PROVIDER_ID") ?? "GOOGLE_GEMINI_OMNI";
const PROVIDER_MODEL = Deno.env.get("PULSE_VIDEO_PROVIDER_MODEL") ?? "gemini-omni-1.2-flash";
const VIDEO_CAP_USD = Number(Deno.env.get("PULSE_VIDEO_CAP_USD") ?? "5.0");

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
    headers: {
      "content-type": "application/json",
      apikey: SERVICE_ROLE,
      authorization: `Bearer ${SERVICE_ROLE}`,
    },
    body: JSON.stringify(args),
  });
  const txt = await res.text();
  let parsed: unknown = null;
  try {
    parsed = txt ? JSON.parse(txt) : null;
  } catch {
    parsed = txt;
  }
  if (!res.ok) throw new Error(`rpc ${fn} ${res.status}: ${String(txt).slice(0, 200)}`);
  return parsed;
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") return new Response("ok", { status: 200, headers: CORS_HEADERS });
  if (req.method !== "POST") return json(405, { status: "METHOD_NOT_ALLOWED" });
  if (!SUPABASE_URL || !SERVICE_ROLE) return json(500, { status: "SERVER_NOT_CONFIGURED" });

  // Authentication.
  const authHeader = req.headers.get("Authorization") ?? "";
  if (!/^Bearer\s+.+/i.test(authHeader)) return json(401, { status: "UNAUTHENTICATED" });
  let userId = "";
  try {
    const u = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
      headers: { apikey: SERVICE_ROLE, authorization: authHeader },
    });
    if (!u.ok) return json(401, { status: "UNAUTHENTICATED" });
    const uj = await u.json();
    userId = String(uj?.id ?? "");
  } catch {
    return json(401, { status: "UNAUTHENTICATED" });
  }
  if (!userId) return json(401, { status: "UNAUTHENTICATED" });

  // Onboarding gate (fail closed).
  try {
    const allowed = await rpc("fn_edge_onboarding_allowed", { p_auth_user_id: userId });
    if (allowed !== true) return json(403, { status: "ONBOARDING_INCOMPLETE" });
  } catch {
    return json(403, { status: "ONBOARDING_INCOMPLETE" });
  }

  let body: Record<string, unknown>;
  try {
    body = (await req.json()) as Record<string, unknown>;
  } catch {
    return json(400, { status: "INVALID_JSON" });
  }
  const jobId = String(body.video_job_id ?? "");
  if (!/^[0-9a-f-]{36}$/i.test(jobId)) return json(400, { status: "INVALID_VIDEO_JOB" });

  // Read the prepared job's estimated cost (tenant-scoped) for the authorization gate.
  let estimatedUsd = 0;
  try {
    const r = await fetch(
      `${SUPABASE_URL}/rest/v1/media_video_jobs?id=eq.${jobId}&tenant_id=eq.${userId}&select=estimated_cost`,
      { headers: { apikey: SERVICE_ROLE, authorization: `Bearer ${SERVICE_ROLE}` } },
    );
    const arr = await r.json();
    const row = Array.isArray(arr) ? arr[0] : null;
    if (!row) return json(404, { status: "VIDEO_JOB_NOT_FOUND" });
    estimatedUsd = Number(row.estimated_cost ?? 0);
  } catch {
    return json(404, { status: "VIDEO_JOB_NOT_FOUND" });
  }

  const deps: VideoExecutorDeps = {
    dispatch: async (id, tenant) =>
      (await rpc("fn_media_dispatch_video_job", { p_job_id: id, p_tenant: tenant })) as never,
    authorize: async (est, cap, model) =>
      (await rpc("fn_video_generation_authorization_state", {
        p_estimated_usd: est,
        p_cap_usd: cap,
        p_model: model,
      })) as never,
    provider: {
      id: PROVIDER_ID,
      model: PROVIDER_MODEL,
      generate: async ({ mode, sourceImageUrl, prompt, durationS, aspectRatio, resolution }) => {
        // Delegate the real Omni Flash image-to-video call to the n8n workflow, which
        // uploads the finished MP4 to the private pulse-generated-media bucket and
        // returns its object ref. One generation call — actual moving video, not frames.
        const res = await fetch(VIDEO_EXECUTOR_WEBHOOK, {
          method: "POST",
          headers: {
            "content-type": "application/json",
            ...(WEBHOOK_SECRET ? { "x-pulse-webhook-secret": WEBHOOK_SECRET } : {}),
          },
          body: JSON.stringify({
            job_id: jobId,
            model: PROVIDER_MODEL,
            mode,
            source_image_url: sourceImageUrl,
            prompt,
            duration_s: durationS,
            aspect_ratio: aspectRatio,
            resolution,
          }),
        });
        const txt = await res.text();
        let d: Record<string, unknown> = {};
        try {
          d = txt ? JSON.parse(txt) : {};
        } catch {
          d = {};
        }
        if (!res.ok || d.ok === false || !d.storage_path) {
          throw new Error(`video_exec:${String(d.reason ?? d.detail ?? res.status)}`);
        }
        return {
          providerJobId: String(d.provider_job_id ?? `vid-${jobId}`),
          storageRef: String(d.storage_ref ?? `pulse-generated-media/${String(d.storage_path)}`),
          mime: String(d.mime ?? "video/mp4"),
          width: Number(d.width ?? 1080),
          height: Number(d.height ?? 1920),
          durationS: Number(d.duration_s ?? durationS),
          actualCostUsd: Number(d.cost_usd ?? 0),
        };
      },
    },
    complete: async (a) =>
      (await rpc("fn_media_complete_video_real", {
        p_job_id: a.jobId,
        p_tenant: a.tenant,
        p_provider: a.provider,
        p_provider_job_id: a.providerJobId,
        p_storage_ref: a.storageRef,
        p_mime: a.mime,
        p_width: a.width,
        p_height: a.height,
        p_duration: a.durationS,
        p_actual_cost: a.actualCostUsd,
        p_cost_currency: a.costCurrency,
        p_product_id: a.productId,
        p_country_code: a.countryCode,
        p_source_asset_refs: a.sourceAssetRefs,
        p_prompt: a.prompt,
        p_provenance: a.provenance,
      })) as Record<string, unknown>,
    retry: async (id, tenant, error) =>
      await rpc("fn_media_retry_video_job", { p_job_id: id, p_tenant: tenant, p_error: error }),
  };

  let result;
  try {
    result = await executeVideoScene({
      jobId,
      tenant: userId,
      productId: null, // fn_media_complete_video_real derives it from canonical lineage
      countryCode: body.country_code ? String(body.country_code) : null,
      capUsd: VIDEO_CAP_USD,
      estimatedUsd,
      deps,
    });
  } catch (e) {
    return json(200, {
      status: "GENERATION_FAILED",
      usable: false,
      retryable: true,
      detail: (e as Error).message,
      message: "Video generation didn't complete. Please try again.",
    });
  }

  if (result.status === "not_dispatchable")
    return json(200, {
      status: "NOT_DISPATCHABLE",
      usable: false,
      detail: result.detail,
      message: "This video job is not ready to generate (run prepare/dispatch gates first).",
    });
  if (result.status === "spend_not_authorized")
    return json(200, {
      status: "SPEND_NOT_AUTHORIZED",
      usable: false,
      authorization: result.authz,
      message:
        "Video generation requires an enabled provider and explicit founder spend authorization within the cost cap; nothing was generated.",
    });
  if (result.status === "provider_failed")
    return json(200, {
      status: "GENERATION_FAILED",
      usable: false,
      retryable: true,
      detail: result.error,
      message: "Video generation didn't complete. Please try again.",
    });

  return json(200, {
    status: "GENERATED_REVIEW_REQUIRED",
    usable: false, // a generated clip is never auto-usable
    video_asset_id: result.assetId,
    launch_safe: false,
    identity_state: "IDENTITY_REVIEW_REQUIRED",
    provider: PROVIDER_ID,
    model: PROVIDER_MODEL,
    auto_published: false,
    message:
      "Video generated for mandatory human identity + approval review. It is not launch-safe and is not published or exported.",
  });
});
