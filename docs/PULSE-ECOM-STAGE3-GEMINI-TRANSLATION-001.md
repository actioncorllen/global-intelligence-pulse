# PULSE-ECOM-STAGE3-GEMINI-TRANSLATION-001

**Stage 3 — approved Gemini text translation under a HARD global $2.00 USD / calendar-month cap.
The money-critical budget core, the server-side Gemini translator (n8n), the budget-enforced
`translate-text` edge function, and the shared translation cache are BUILT, DEPLOYED and VERIFIED
end-to-end with a real budget-bracketed call. The founder-approved `gemini-2.5-flash-lite` proved
access-denied on this API key ("no longer available to new users"); after confirming which models
the key can actually reach, the founder authorised `gemini-3.1-flash-lite` ($0.25 in / $1.50 out
per 1M — Google's most cost-effective Flash-Lite). The cost function was recalibrated to that rate
so the $2 ceiling stays a true $2 at Google. Backend + budget fully verified; frontend wiring +
production publish are the remaining step.**

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

## 5. Model selection (access-verified) + recalibration
The first real call exposed that the founder-approved `gemini-2.5-flash-lite` returns **HTTP 404**
*"no longer available to new users … use models/gemini-3.5-flash-lite"* — it is in the model catalog
but this project is blocked from generating with it (a per-project new-user gate on older models).
Gemini was **not billed** on that 404 (no `usageMetadata`); the reservation was released (actual 0),
net spend $0.00.

A free `models.list` with this key showed the accessible generateContent models. Cheapest options
verified: **`gemini-3.1-flash-lite` $0.25 / $1.50 per 1M** (Google's "most cost-effective"),
`gemini-3.5-flash-lite` $0.30 / $2.50, and Gemma 4 (free tier, but data may be used to improve Google
products + lower limits). The founder authorised **`gemini-3.1-flash-lite`**. `fn_translation_cost_micro`
was recalibrated from $0.10/$0.40 to **$0.25/$1.50** (×1.5 margin), keeping the $2 ceiling a true $2
at Google; the cap self-test re-passed 9/9 at the new rate (cost 263, worst-case 731). The model is
now sent by the edge function to n8n (default `gemini-3.1-flash-lite`), so a future model change is a
one-line edge-function edit + a cost recalibration.

## 6. End-to-end verification (real call, budget-enforced) — PASS
Walked the exact enforced sequence with one real Gemini 3.1 Flash-Lite call (reserve → n8n/Gemini →
reconcile actual → cache → read-back), translating 3 unseen multilingual titles (DE/ES/FR):
- Reserve: worst-case **2195 µUSD**, remaining 1,997,805.
- Gemini 3.1 Flash-Lite: HTTP 200, `finishReason STOP`, usage 250 in / 80 out. Translations preserved
  every brand, model code and number — e.g. *"Philips Lumea IPL Haarentfernungsgerät 9000 Serie
  BRI958/00"* → *"Philips Lumea IPL Hair Removal Device 9000 Series BRI958/00"*; De'Longhi EC885.M
  1300W and Sony WF-1000XM5 kept verbatim.
- Reconcile: actual **274 µUSD** ($0.000274), clamped under the 2195 reservation; month `spent=274,
  reserved=0, remaining=1,999,726`, 0 open reservations.
- Cache: 3 entries written (`gemini_3_1_flash_lite`); a repeat lookup now returns all 3 as free hits.
- Verdict: reserve → real call → reconcile-actual → cache → free-hit all correct; brands/SKUs/numbers
  preserved; cap enforced; fail-closed + over-cap refusal proven by the 9/9 self-test. **PASS.**

## 7. Frontend wired + published (Lovable commit 844987b4) — LIVE
The Product Explorer now translates product **titles** into the visitor's language WORLDWIDE through
the budget-enforced `translate-text` edge function, reusing the existing language layer + cache:
- New `contentLang` on `LanguageProvider`: Preferences override → account/browser locale primary
  subtag → fallback; independent of the research market. `useTextTranslations` is cache-first, then
  calls `translate-text` for the misses only (batched ≤40 items / ≤12k chars, deduped), non-blocking
  (originals render immediately, update in place), and **fails closed** (budget-exhausted / error →
  originals kept, no error UI). `marketSourceLang` passes a source-language hint. Originals, brands,
  SKUs, numbers and the "Translated" badge are preserved; no browser-side Gemini/secret.
- Frontend 319/319 tests pass, `tsc --noEmit` clean, no lint errors. Published to
  globalintelligenceactions.com and **bundle-verified live**: `translate-text`, `text-translations`,
  `fn_text_translations`, `contentLang` and the "Translated" badge all present; and FX
  (`fn_fx_convert`/ECB), `fn_ecommerce_supported_markets`, `fn_product_explorer`, Preferences,
  `strateloq.lang`, "Not researched"/"Nicht recherchiert" and Product Asset Lock all still present —
  no regression.

## 8. Extended beyond titles — descriptions + human categories (mig_317; Lovable 85a829cf) — LIVE
After titles, the only GENUINE additional free-text in the server contracts was product
`description` and `category`, which `fn_product_explorer` did not expose. mig_317 additively surfaces
both existing columns (blanks stripped — never invented). The frontend now:
- Renders a **Description** block in the Product Intelligence drawer ONLY when a genuine description
  is present, translated through the same path (cache-first → translate-text), original preserved +
  "Translated" badge, non-blocking, fail-closed; German "Beschreibung" added.
- Translates `category` ONLY when human-readable (`isMachineSlug`/`humanCategory`): machine slugs
  like `tiktok_shop_product` are never sent to translate-text and never shown as labels.
- Adds description + eligible category to the SAME deduped/batched title request (one pipeline).
- 322/322 frontend tests pass, tsc clean; published + bundle-verified live (`Beschreibung` present,
  the slug literal absent, no regression to FX/18-market/Explorer/Preferences/Asset-Lock).

### What the current data means (honest)
The *contract + UI are ready*, but with the **current live discovery data** there is little extra
text to show: product descriptions are essentially unpopulated (≈0 of the GB/DE discovery set), and
the Explorer `category` is the machine slug `tiktok_shop_product` (hidden, never translated). So the
visible translated surface today remains chiefly **titles**; descriptions/human categories will
translate automatically once such genuine text exists. Nothing is fabricated to fill the gap.

### Intelligence summaries + workspace chrome (PARTIAL, by design)
The Product Intelligence drawer contract (`fn_ecommerce_product_intelligence`) is **structured /
controlled-vocabulary** — states, counts, enums (lifecycle, decision, evidence-family states) and
canonical identity tokens (brand/SKU-class, must NOT be translated). There is no free-text "summary"
prose to send to Gemini; those labels are localised through the EN/DE i18n dictionary (English
fallback worldwide). Translating enums via Gemini would risk changing their exact meaning, so it is
deliberately NOT done. Full worldwide UI chrome would require either authored dictionaries per
language or routing controlled vocab through Gemini (rejected for meaning-safety) — chrome therefore
stays EN/DE authored + English fallback: **PARTIAL**, unchanged from the prior stage.

### Signed-in visual (owed, honest)
The edge function is JWT-gated, so live translation only fires for a signed-in member; this
environment cannot hold a session. The full budget-enforced path was verified server-side with a
real call (§6) and the client wiring is confirmed present in the live bundle, but the pixel-level
signed-in experience (e.g. a French browser seeing translated titles/descriptions) must be confirmed
by a member. **Not claimed as visually verified.**

## 7. Preserved / not changed
$2/month hard cap + fail-closed semantics, tenant/global budget isolation, translation cache,
server-side credentials (Gemini key stays in n8n; budget stays in Supabase; browser holds neither),
Product Asset Lock and all prior Explorer/evidence/FX/18-market/EN-DE work. No unapproved paid
provider calls. Stopped at Stage 3.
