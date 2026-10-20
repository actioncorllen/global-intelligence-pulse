# PULSE-ECOM-STAGE3-LOCALISATION-001

**Stage 3 Global Localisation. Automatic display-currency detection + conversion using the EXISTING,
already-authorised FX capability (ECB via frankfurter.app; `mig_314` `fn_fx_convert`), automatic UI
language with no forced prompt (Settings override only), and language / currency / research-market kept
independent. No new paid APIs, no rebuild. Backend selftest 5/5; frontend 315/315; published to
globalintelligenceactions.com and bundle-verified. Automatic translation of NEW/unseen free-text is a
genuine external BLOCKER (no authorised text-translation capability exists) and is reported, not faked.**

## Capability audit (reuse / blockers)
- **FX / currency — EXISTS, reused.** `get_fx_rate` over `fx_rates`, sourced from **ECB via
  frankfurter.app** (a free, already-authorised feed) and refreshed daily by the existing ingest
  (newest fetch 2026-10-20 06:00; 29 quote currencies + USD base; `as_of` dated; `stale` flag). Genuine,
  dated, worldwide-enough to cover all 18 markets + major display currencies.
- **Text translation engine — DOES NOT EXIST.** The only authorised AI capability is **Google Gemini
  via n8n** (`commercial-image-generate` → tradingb.app.n8n.cloud, `gemini-2.5-flash-image`), and it is
  **image-only** — there is no text-translation workflow or endpoint. Enabling Gemini *text* translation
  would be incremental paid usage requiring founder approval. **Not built** (constraint: no paid APIs
  without approval). This is the Stage-3 blocker.

## 1. Display-currency detection + conversion (req 3) — PASS
`mig_314` adds `fn_fx_convert(from, to, amount)` (`pulse_fx_convert_v1`): a SECURITY DEFINER read wrapper
over `get_fx_rate` (needed because `fx_rates` is RLS-locked and `get_fx_rate` is invoker-rights). It
returns a genuine dated rate + converted value, or `available:false` for an unknown pair — **rates are
never invented**. auth-gated; selftest **5/5** (unauth fail-closed, currency gate, identity=1, a real
cross rate with `as_of`, unknown pair not invented).
Frontend: `fx-contract.ts` (fail-closed decoder + display-currency detection from browser locale),
`use-fx-convert.ts` (ONE dated ECB rate per currency pair, 1h cache, no retry), and
`ConvertedPrice`/`FxSecondary`. The **original amount + currency is always the primary value**; a
secondary "≈ {converted} · ECB · {as_of}" appears only when a genuine rate is available, with a "(rate
may be delayed)" note when stale, and **nothing** (original only) when unavailable. Applied to Explorer
card prices, the drawer observed price, and the competitor price range/rows. Numeric source VALUES are
never mutated — conversion is display-only.

## 2. Automatic UI language, no forced prompt (req 1) — PARTIAL
Language auto-detects from account/browser locale with **no prompt**. The EN/DE control was moved out of
the header into a **Preferences** (gear) menu holding OPTIONAL overrides only — Language (Auto / English
/ Deutsch) and Display currency (Auto / specific / keep market currency) — persisted in localStorage.
Worldwide locales are detected and mapped to a supported UI language; **English and German** are authored
and everything else falls back to English (honest; no fabricated other-language UI). Full worldwide UI +
content localisation depends on the blocked translation engine (§ blocker).

## 3. Automatic translation of unseen free-text (req 2) — BLOCKED
Known/seeded product text continues to use the `fn_text_translations` cache (unchanged); uncached
free-text shows the **original** unchanged. Automatic translation of new/unseen text was **not** wired:
no authorised text-translation capability exists and enabling Gemini-text translation is incremental
paid usage needing approval. Decision needed: approve Gemini-text translation (with a budget) and a
text workflow, or nominate another authorised translation capability.

## 4. Independence + preserved (req 4, 5)
UI language, display currency and research market (`?country=`) are **independent** — changing one never
changes the others. Preserved: all 18 markets + the selector, country/tenant isolation, product
identity, brand, SKU, variants, numeric metric values, evidence provenance, REFERENCE_ONLY media,
Product Asset Lock (`concreteProductActionsAllowed={false}`), the hero image, the evidence "Not
researched" fix, the ad/competitor sections, and the EN/DE + translation-cache work. No unrelated
upgrades or rebuilds.

## 5. Verification
- Backend: `fn_fx_convert_selftest` **5/5**; `mig_314` committed + deployed.
- Frontend: **315/315** tests (49 files), `tsc --noEmit` + build clean; new tests cover currency
  auto-detect from locale, converted + ECB `as_of` label with original value unchanged, unavailable →
  original only (no fabrication), stale note, auto-language no-prompt + persisted override, and
  language/currency/market independence.
- Live (bundle-verified on globalintelligenceactions.com): `fn_fx_convert`, `ECB`, "rate may be
  delayed", "Preferences", "Display currency", `strateloq.lang` all present; prior features
  (`fn_ecommerce_supported_markets`, `fn_text_translations`, `fn_product_explorer`, ad/competitor, hero,
  "Not researched", Asset Lock, German dictionary) all still present — **no regression**.

## Status vs worldwide localisation
- **Currency conversion (req 3): PASS** — genuine dated ECB rates, original preserved + labelled, never
  invented, independent. (Signed-in visual still to be confirmed by a member.)
- **Automatic language detection, no forced prompt, Settings override (req 1, 5): PASS for behaviour;
  PARTIAL for coverage** — detection is worldwide, but authored UI is EN/DE with an English fallback.
- **Automatic translation of new/unseen free-text (req 2): BLOCKED** — no authorised text-translation
  capability; needs founder approval to enable Gemini-text translation (paid) or another service.
- **Independence + preservation (req 4, 5): PASS.**

### Not claimed / next decision
Signed-in member verification is still required (this environment cannot hold a session) — **no full
visual PASS is claimed**. To lift the Stage-3 blocker, the founder decides on an authorised, budgeted
translation path; the cache + lookup is the reusable mechanism to store its output. Per instruction,
**stopped at Stage 3** — no research enrichment, saturation, or country recommendations started.
