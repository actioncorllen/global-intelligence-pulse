// PULSE-ECOM-P14-PERFORMANCE-INTELLIGENCE-001
// READ-ONLY Meta Insights reader. Never activates, never mutates budgets, never spends.
// Token resolved ONLY from env; never returned/logged. Zero-delivery is valid evidence.

const GRAPH_VERSION = "v26.0";
const GRAPH_HOST = "https://graph.facebook.com";

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}
function redact(input: unknown): string {
  let s = typeof input === "string" ? input : JSON.stringify(input ?? "");
  const tok = Deno.env.get("META_CAPI_ACCESS_TOKEN");
  if (tok && tok.length > 0) s = s.split(tok).join("[REDACTED_TOKEN]");
  s = s.replace(/access_token=[^&"]+/gi, "access_token=[REDACTED]");
  return s.slice(0, 800);
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return jsonResponse(405, { ok: false, error: "method_not_allowed" });
  let body: any;
  try { body = await req.json(); } catch { return jsonResponse(400, { ok: false, error: "invalid_json" }); }
  const objectId = String(body.object_id || "");
  if (!objectId) return jsonResponse(400, { ok: false, error: "object_id_required" });

  const token = Deno.env.get("META_CAPI_ACCESS_TOKEN");
  if (!token) return jsonResponse(424, { ok: false, error: "server_token_unavailable" });

  const fields = "spend,impressions,reach,frequency,clicks,inline_link_clicks,actions,action_values";
  const url = `${GRAPH_HOST}/${GRAPH_VERSION}/${objectId}/insights?fields=${fields}&access_token=${encodeURIComponent(token)}`;
  try {
    const r = await fetch(url, { method: "GET" }); // READ-ONLY
    const j = await r.json().catch(() => ({}));
    return jsonResponse(200, {
      ok: r.ok, http_status: r.status, object_id: objectId,
      data: Array.isArray(j?.data) ? j.data : null,       // empty array == zero delivery (valid)
      zero_delivery: Array.isArray(j?.data) && j.data.length === 0,
      error: r.ok ? null : redact(j?.error?.message ?? j),
      error_code: j?.error?.code ?? null,
      error_subcode: j?.error?.error_subcode ?? null,
    });
  } catch (e) {
    return jsonResponse(502, { ok: false, object_id: objectId, error: redact((e as Error).message) });
  }
});
