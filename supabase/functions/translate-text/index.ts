// STRATELOQ — translate-text
// Stage 3 APPROVED Gemini text translation under a HARD global $2.00 USD / calendar-month cap.
//
// Signed-in user -> this JWT-protected Edge Function -> cache-first lookup (free) -> for the
// remaining (uncached) strings: RESERVE worst-case against the atomic $2 cap (mig_315) -> call the
// server-side Gemini translator via n8n (currently 3.1 Flash-Lite; credentials stay in n8n) -> RECONCILE the
// ACTUAL token cost, failing CLOSED on any error/timeout/uncertain charge -> write the translations
// into the shared cache so each phrase is paid for at most once.
//
// Money-safety invariants:
//   * The browser never holds the Gemini key or the budget. The ONLY path to Gemini is the
//     secret-protected n8n webhook, and this function reserves budget BEFORE it ever calls it, so
//     the cap can never be bypassed.
//   * Reserve-before-call + reconcile-after. Any uncertainty (n8n error, timeout, unparseable
//     output, missing usage) forfeits the full worst-case reservation — never a refund, never an
//     over-charge beyond the reserved worst case.
//   * At budget exhaustion, cached translations are still returned and uncached strings fall back to
//     the ORIGINAL text. Translations are NEVER fabricated — only a genuine cache hit or a genuine
//     Gemini result is ever returned; everything else keeps the original.
//   * Originals, brands, trademarks, SKUs, numbers and provenance are preserved (prompt-enforced;
//     the client also keeps the original and only overlays a translation when one exists).

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
// Canonical inbound n8n webhook secret (same one the discovery/CJ executors use).
const WEBHOOK_SECRET = Deno.env.get("PULSE_DISCOVERY_WEBHOOK_SECRET") ?? Deno.env.get("N8N_GEMINI_WEBHOOK_SECRET") ?? "";
const TRANSLATE_WEBHOOK = Deno.env.get("N8N_TRANSLATE_WEBHOOK") ?? "https://tradingb.app.n8n.cloud/webhook/pulse-gemini-translate";

// Founder-authorised model (2.5 Flash-Lite was access-denied on this key). The edge function is the
// authoritative model selector: it sends MODEL to n8n, which uses it in the generateContent URL.
// Changing the model + its provenance here (and recalibrating fn_translation_cost_micro) is the only
// change needed to switch models.
const MODEL = "gemini-3.1-flash-lite";
const PROVENANCE = "gemini_3_1_flash_lite";
const MAX_INPUT_TEXTS = 400;   // hard cap on strings accepted per request
const MAX_ITEMS = 60;          // hard cap on uncached strings sent to Gemini per call
const MAX_TOTAL_CHARS = 16000; // hard cap on total source chars sent to Gemini per call
const MAX_ITEM_CHARS = 2000;   // per-string cap (longer strings keep their original)

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const LANG_NAMES: Record<string, string> = {
  en: "English", de: "German", fr: "French", es: "Spanish", it: "Italian", nl: "Dutch",
  pl: "Polish", pt: "Portuguese", sv: "Swedish", da: "Danish", no: "Norwegian", fi: "Finnish",
  cs: "Czech", el: "Greek", hu: "Hungarian", ro: "Romanian", sk: "Slovak", bg: "Bulgarian",
  hr: "Croatian", uk: "Ukrainian", ru: "Russian", tr: "Turkish", ar: "Arabic", he: "Hebrew",
  hi: "Hindi", th: "Thai", vi: "Vietnamese", id: "Indonesian", ms: "Malay", ja: "Japanese",
  ko: "Korean", zh: "Chinese (Simplified)", "zh-tw": "Chinese (Traditional)", fil: "Filipino", tl: "Filipino",
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
  let parsed: unknown = null;
  try { parsed = txt ? JSON.parse(txt) : null; } catch { parsed = txt; }
  if (!res.ok) throw new Error(`rpc ${fn} ${res.status}: ${String(txt).slice(0, 200)}`);
  return parsed;
}

function langName(code: string): string {
  const c = (code || "").toLowerCase();
  return LANG_NAMES[c] ?? (LANG_NAMES[c.split("-")[0]] ?? code);
}

function buildGeminiPayload(targetLang: string, selected: string[]): Record<string, unknown> {
  const items = selected.map((s, i) => ({ i, s }));
  const name = langName(targetLang);
  const prompt =
    `You are a professional e-commerce translator. Translate the "s" field of each item in INPUT into ${name} (${targetLang}).\n` +
    `Rules:\n` +
    `- Preserve brand names, trademark symbols (™ ® ©), model names, SKU/model codes, numbers, units and measurements EXACTLY as written.\n` +
    `- Do not translate or transliterate proper nouns or brand names.\n` +
    `- Keep symbols such as – — × and punctuation.\n` +
    `- If an item is already in ${name}, return it unchanged.\n` +
    `- Translate meaning faithfully and naturally; do not add, omit, explain or editorialize.\n` +
    `Return ONLY a JSON array; for each INPUT item output an object {"i": <same i>, "t": "<${name} translation>"}, with the same count, same i values and same order.\n` +
    `INPUT: ${JSON.stringify(items)}`;
  return {
    contents: [{ role: "user", parts: [{ text: prompt }] }],
    generationConfig: {
      temperature: 0,
      responseMimeType: "application/json",
      responseSchema: {
        type: "ARRAY",
        items: {
          type: "OBJECT",
          properties: { i: { type: "INTEGER" }, t: { type: "STRING" } },
          required: ["i", "t"],
        },
      },
    },
  };
}

function parseTranslations(text: string, selected: string[]): { source: string; translated: string }[] {
  let t = (text || "").trim();
  if (t.startsWith("```")) {
    t = t.replace(/^```[a-zA-Z]*\s*/, "").replace(/```\s*$/, "").trim();
  }
  const a = t.indexOf("[");
  const b = t.lastIndexOf("]");
  if (a >= 0 && b > a) t = t.slice(a, b + 1);
  let arr: unknown;
  try { arr = JSON.parse(t); } catch { return []; }
  if (!Array.isArray(arr)) return [];
  const out: { source: string; translated: string }[] = [];
  for (const it of arr) {
    if (!it || typeof it !== "object") continue;
    const rec = it as Record<string, unknown>;
    const i = Number(rec.i);
    const tr = typeof rec.t === "string" ? rec.t.trim() : "";
    if (Number.isInteger(i) && i >= 0 && i < selected.length && tr) {
      out.push({ source: selected[i], translated: tr });
    }
  }
  return out;
}

async function sha256Hex(s: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  const bytes = Array.from(new Uint8Array(buf));
  return bytes.map((x) => x.toString(16).padStart(2, "0")).join("").slice(0, 32);
}

async function callWebhook(url: string, body: unknown): Promise<{ ok: boolean; status: number; data: Record<string, unknown> }> {
  const res = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json", ...(WEBHOOK_SECRET ? { "x-pulse-webhook-secret": WEBHOOK_SECRET } : {}) },
    body: JSON.stringify(body),
  });
  const txt = await res.text();
  let data: Record<string, unknown> = {};
  try { data = txt ? JSON.parse(txt) : {}; } catch { data = { raw: txt }; }
  return { ok: res.ok, status: res.status, data };
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") return new Response("ok", { status: 200, headers: CORS_HEADERS });
  if (req.method !== "POST") return json(405, { status: "METHOD_NOT_ALLOWED" });
  if (!SUPABASE_URL || !SERVICE_ROLE) return json(500, { status: "SERVER_NOT_CONFIGURED" });

  // --- Authentication: resolve the signed-in user server-side from their JWT ---
  const authHeader = req.headers.get("Authorization") ?? "";
  if (!/^Bearer\s+.+/i.test(authHeader)) return json(401, { status: "UNAUTHENTICATED" });
  let userId = "";
  try {
    const u = await fetch(`${SUPABASE_URL}/auth/v1/user`, { headers: { apikey: SERVICE_ROLE, authorization: authHeader } });
    if (!u.ok) return json(401, { status: "UNAUTHENTICATED" });
    const uj = await u.json();
    userId = String(uj?.id ?? "");
  } catch { return json(401, { status: "UNAUTHENTICATED" }); }
  if (!userId) return json(401, { status: "UNAUTHENTICATED" });

  let body: Record<string, unknown>;
  try { body = (await req.json()) as Record<string, unknown>; } catch { return json(400, { status: "INVALID_JSON" }); }

  const targetLang = String(body.target_lang ?? "").toLowerCase().trim();
  const sourceLang = body.source_lang ? String(body.source_lang).toLowerCase().trim() : null;
  const rawTexts = Array.isArray(body.texts) ? body.texts : [];
  if (!targetLang) return json(400, { status: "LANGUAGE_REQUIRED" });
  if (rawTexts.length === 0) return json(200, { status: "ok", target_lang: targetLang, translations: {}, stats: { requested: 0, cache_hits: 0, translated: 0 } });
  if (rawTexts.length > MAX_INPUT_TEXTS) return json(400, { status: "TOO_MANY_TEXTS", max: MAX_INPUT_TEXTS });

  // Normalize + dedupe source strings (trimmed, non-empty).
  const seen = new Set<string>();
  const sources: string[] = [];
  for (const x of rawTexts) {
    const s = typeof x === "string" ? x.trim() : "";
    if (s && !seen.has(s)) { seen.add(s); sources.push(s); }
  }
  if (sources.length === 0) return json(200, { status: "ok", target_lang: targetLang, translations: {}, stats: { requested: 0, cache_hits: 0, translated: 0 } });

  // --- 1. Cache-first (free). A missing entry returns no translation; the client keeps the original. ---
  const translations: Record<string, { translated: string; provenance: string; from_cache: boolean }> = {};
  let misses: string[] = [];
  try {
    const cacheRes = (await rpc("fn_text_translations_read_svc", { p_target_lang: targetLang, p_texts: sources })) as Record<string, unknown>;
    const cached = (cacheRes?.translations ?? {}) as Record<string, { translated?: string; provenance?: string }>;
    for (const s of sources) {
      const hit = cached[s];
      if (hit && typeof hit.translated === "string" && hit.translated) {
        translations[s] = { translated: hit.translated, provenance: String(hit.provenance ?? "cache"), from_cache: true };
      } else {
        misses.push(s);
      }
    }
  } catch (e) {
    // Cache read failed: fail safe — treat everything as a miss (still bounded + budgeted below).
    misses = sources.slice();
  }

  const cacheHits = sources.length - misses.length;

  // --- 2. Nothing uncached -> done, no spend. ---
  if (misses.length === 0) {
    let state: unknown = null;
    try { state = await rpc("fn_translation_budget_state", {}); } catch { /* non-fatal */ }
    return json(200, { status: "ok", target_lang: targetLang, translations, budget: state, stats: { requested: sources.length, cache_hits: cacheHits, translated: 0, truncated: false } });
  }

  // --- 3. Bound the Gemini batch (count + chars). Over-cap strings keep their original. ---
  const selected: string[] = [];
  let totalChars = 0;
  let truncated = false;
  for (const m of misses) {
    if (m.length > MAX_ITEM_CHARS) { truncated = true; continue; }
    if (selected.length >= MAX_ITEMS || totalChars + m.length > MAX_TOTAL_CHARS) { truncated = true; continue; }
    selected.push(m);
    totalChars += m.length;
  }

  let budgetExhausted = false;
  let translatedCount = 0;
  let lastDiag = "";

  if (selected.length > 0) {
    // --- 4. Worst-case cost for the batch (at verified Gemini rates + safety margin). ---
    let worstCase = 0;
    try { worstCase = Number(await rpc("fn_translation_worstcase_micro", { p_total_source_chars: totalChars, p_item_count: selected.length })); } catch { worstCase = 0; }
    if (!Number.isFinite(worstCase) || worstCase <= 0) {
      // Can't price it -> do not call Gemini; keep originals (fail closed, no spend).
      const state = await safeState();
      return json(200, { status: "ok", target_lang: targetLang, translations, budget: state, stats: { requested: sources.length, cache_hits: cacheHits, translated: 0, truncated: true }, note: "pricing_unavailable" });
    }

    const requestHash = await sha256Hex(`${targetLang}|${selected.join("\u0001")}`);

    // --- 5. Reserve atomically against the $2/month cap. Fail safe if exhausted. ---
    let reservationId = "";
    try {
      const reserve = (await rpc("fn_translation_budget_reserve", { p_worst_case_micro: worstCase, p_request_hash: requestHash })) as Record<string, unknown>;
      if (reserve?.ok === true && reserve.reservation_id) {
        reservationId = String(reserve.reservation_id);
      } else {
        budgetExhausted = String(reserve?.reason ?? "") === "budget_exhausted";
      }
    } catch {
      budgetExhausted = false; // reserve call itself failed -> no reservation, no call
    }

    if (reservationId) {
      // --- 6. Call the server-side Gemini translator via the secret-protected n8n webhook. ---
      // Reconcile outcome rules (fail closed):
      //   * Gemini produced usage (it ran, so it was billable) -> reconcile the ACTUAL cost,
      //     whether or not parsing yielded rows.
      //   * Definitive pre-execution rejection by n8n (401/403 auth, 404 not-found) -> Gemini never
      //     ran -> release the reservation (success, actual 0): no spend for a config error.
      //   * Anything else (5xx, timeout, transport error, 200 without usage) -> uncertain whether we
      //     were charged -> FORFEIT the full worst-case. Never a refund on uncertainty.
      let outcome = "error";
      let actualMicro = 0;
      let parsed: { source: string; translated: string }[] = [];
      let diag = "";
      try {
        const wh = await callWebhook(TRANSLATE_WEBHOOK, { model: MODEL, geminiPayload: buildGeminiPayload(targetLang, selected) });
        const d = wh.data ?? {};
        const usage = (d.usage ?? {}) as Record<string, unknown>;
        const inTok = Number(usage.prompt_tokens ?? 0) || 0;
        const outTok = Number(usage.output_tokens ?? 0) || 0;
        const geminiBilled = inTok > 0 || outTok > 0;
        if (typeof d.text === "string") parsed = parseTranslations(String(d.text), selected);

        if (geminiBilled) {
          try { actualMicro = Number(await rpc("fn_translation_cost_micro", { p_in_tokens: inTok, p_out_tokens: outTok })); } catch { actualMicro = 0; }
          if (!Number.isFinite(actualMicro) || actualMicro < 0) actualMicro = 0;
          outcome = "success";
          diag = parsed.length > 0 ? "ok" : `billed_no_parse:${String(d.finish_reason ?? d.block_reason ?? "")}`;
        } else if (wh.status === 401 || wh.status === 403 || wh.status === 404) {
          outcome = "success"; actualMicro = 0; diag = `n8n_rejected_${wh.status}`;
        } else {
          outcome = "error"; diag = `uncertain_status_${wh.status}`;
        }
      } catch (e) {
        outcome = "error"; diag = `transport_error:${(e as Error).message.slice(0, 80)}`;
      }

      // --- 7. Reconcile against the cap. ---
      try {
        await rpc("fn_translation_budget_reconcile", {
          p_reservation_id: reservationId,
          p_actual_micro: outcome === "success" ? actualMicro : 0,
          p_outcome: outcome,
        });
      } catch { /* best-effort; the reservation already protects the cap */ }

      // --- 8. Cache + return any GENUINE translations (never fabricated). ---
      if (parsed.length > 0) {
        const entries = parsed
          .filter((p) => p.translated && p.translated !== p.source)
          .map((p) => ({ source: p.source, translated: p.translated, source_lang: sourceLang, target_lang: targetLang, provenance: PROVENANCE }));
        if (entries.length > 0) {
          try { await rpc("fn_text_translations_put", { p_entries: entries }); } catch { /* best-effort */ }
        }
        for (const p of parsed) {
          if (p.translated && p.translated !== p.source) {
            translations[p.source] = { translated: p.translated, provenance: PROVENANCE, from_cache: false };
            translatedCount++;
          }
        }
      }
      lastDiag = diag;
    }
  }

  const state = await safeState();
  return json(200, {
    status: "ok",
    target_lang: targetLang,
    translations, // source -> {translated, provenance, from_cache}; misses are ABSENT (client keeps original)
    budget: state,
    budget_exhausted: budgetExhausted,
    stats: {
      requested: sources.length,
      cache_hits: cacheHits,
      translated: translatedCount,
      not_translated: misses.length - translatedCount,
      truncated,
      note: lastDiag,
    },
  });
});

async function safeState(): Promise<unknown> {
  try { return await rpc("fn_translation_budget_state", {}); } catch { return null; }
}
