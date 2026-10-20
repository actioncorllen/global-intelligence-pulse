# PULSE-ECOM-STAGE3-GEMINI-TRANSLATION-001

**Stage 3 — approved Gemini text translation under a HARD global $2.00 USD / calendar-month cap.
The money-critical budget core, the server-side Gemini translator (n8n), the budget-enforced
`translate-text` edge function, and the shared translation cache are all BUILT, DEPLOYED and
VERIFIED. One genuine external BLOCKER remains: the founder-approved model `gemini-2.5-flash-lite`
is access-denied on this API key, and the API-recommended replacement (`gemini-3.5-flash-lite`) is
materially more expensive, so it needs founder authorisation + a cost recalibration before any live
translation. No model was switched; net paid spend to date = $0.00.**

## 1. Budget core (mig_315) — VERIFIED PASS (9/9)
Atomic, global, per-calendar-month $2.00 cap. `reserve-worst-case-before-call` +
`reconcile-actual-after`, failing CLOSED on any error/retry/concurrency/uncertain charge (forfeits
the full worst-case, never refunds, never over-charges beyond the reserved worst-case). Tables
`translation_budget_month` / `translation_spend_ledger` (RLS on, service_role only). Verified
through the REAL reservation API via `fn_translation_budget_selftest` (v2) — no direct counter
UPDATEs, no DELETE, all writes in a rolled-back subtransaction: reserve+remaining math, success
(spend=actual, surplus returned), idempotent no-double-spend, fail-closed forfeit (full worst-case),
reserve to the exact cap boundary, one-microdollar-over-cap REFUSED with no mutation, unknown
reservation denied, cost/worst-case helpers. Committed `e30b0e0`.

## 2. Service-side cache reader (mig_316) — DEPLOYED
`fn_text_translations_read_svc(target_lang, texts)` — the read counterpart to
`fn_text_translations_put` (mig_315), service_role only, WITHOUT the `auth.uid()` gate, because the
edge function authenticates the user itself and then reads the shared (non-tenant) cache under the
service role. Without this the uid-gated `fn_text_translations` returns nothing under service_role
and the cache would be defeated. The browser keeps using the uid-gated `fn_text_translations`.

## 3. Gemini text translator (n8n) — BUILT + PUBLISHED
Workflow `Pulse — Gemini Text Translator` (`ux0swIkKaYN6rAfJ`), published and active:
`Translate Request` webhook (**headerAuth**, `x-pulse-webhook-secret`, canonical credential
`ew4z88ejs40FCkqi` — the same secret the discovery/CJ executors use) → `Gemini Translate`
(`httpRequest` to `generativelanguage.googleapis.com/.../<model>:generateContent`, server-side
`googlePalmApi` credential `DfgUa43wDIdJPMQC`) → `Shape Response` (returns `{ok,status,text,usage,
finish_reason,block_reason}` with token counts). The webhook is **secret-validated**, so the only
caller that can reach Gemini is the budget-enforcing edge function — direct-n8n bypass is closed.

## 4. Budget-enforced path (`translate-text` edge function) — DEPLOYED
`verify_jwt` edge function. Flow: resolve signed-in user → normalise+dedupe texts → **cache-first**
(`fn_text_translations_read_svc`, free) → for uncached strings, bound the batch (≤60 items /
≤16k chars) → `fn_translation_worstcase_micro` → **reserve** (`fn_translation_budget_reserve`) →
call the secret-protected n8n translator → **reconcile actual** token cost
(`fn_translation_cost_micro` → `fn_translation_budget_reconcile`), failing closed on any
uncertainty → **cache-write** (`fn_text_translations_put`). Guarantees: budget reserved before any
Gemini call (never bypassable); at exhaustion, cache hits still returned and uncached strings fall
back to the ORIGINAL (never fabricated); originals/brands/SKUs/numbers preserved (prompt-enforced +
client keeps original). A definitive pre-execution rejection (n8n 401/403/404 — Gemini never ran)
releases the reservation instead of wastefully forfeiting it.

## 5. End-to-end verification (real call, budget-enforced) — path PASS; model BLOCKED
Walked the exact enforced sequence with one real Gemini call (reserve → n8n/Gemini → reconcile →
state), translating 3 unseen multilingual titles (DE/ES/FR) with brands + model codes + numbers:
- Reserve: worst-case **648 µUSD**, remaining 1,999,352 — correct.
- Gemini call returned **HTTP 404**: `models/gemini-2.5-flash-lite` *"is no longer available to new
  users … use models/gemini-3.5-flash-lite"*. Gemini was **not billed** (no `usageMetadata`).
- Shape Response captured the failure cleanly (`ok:false, status:404`); reservation released
  (reconciled, actual 0). **Net spend $0.00**; month back to `reserved=0, spent=0, remaining=$2.00`,
  0 open reservations.
- Verdict: the n8n executor, the secret gate, the reserve/reconcile accounting and the cache plumbing
  all behaved correctly. The ONLY failure was model availability.

## 6. BLOCKER — model authorisation + pricing (founder decision)
- **Approved model `gemini-2.5-flash-lite` ($0.10 in / $0.40 out per 1M) is access-denied** on this
  API key (404 for new users).
- **API-recommended replacement `gemini-3.5-flash-lite` = $0.30 in / $2.50 out per 1M** (~3× input,
  ~6× output; launched Jul 2026; verified across multiple price trackers).
- The $2/month HARD cap holds regardless of model (the reserve gate is model-agnostic), but the
  cost-per-token model (`fn_translation_cost_micro`, currently calibrated to $0.10/$0.40) MUST be
  recalibrated to the chosen model's real rate, or the counter would under-count Google spend and the
  "$2" could overshoot at Google. At 3.5-Lite rates the same $2 buys proportionally fewer
  translations.
- **Not done unilaterally**: no model switched, no further paid calls. Options for the founder:
  (a) authorise `gemini-3.5-flash-lite` — then recalibrate the cost function to $0.30/$2.50 (+margin)
  and flip the model; the $2 cap stays a true $2; (b) nominate another available model; (c) keep
  translation disabled — the cache + originals path already works and shows original text everywhere.

## 7. Preserved / not changed
$2/month hard cap + fail-closed semantics, tenant/global budget isolation, translation cache,
server-side credentials (Gemini key stays in n8n; budget stays in Supabase; browser holds neither),
Product Asset Lock and all prior Explorer/evidence/FX/18-market/EN-DE work. No unapproved paid
provider calls. Stopped at Stage 3.
