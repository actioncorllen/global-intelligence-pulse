# PULSE-ECOM-MULTILINGUAL-18MARKET-001

**18-Market & Multilingual Explorer stage. All 18 configured countries in the Explorer selector (reusing
the existing `fn_ecommerce_supported_markets`), an internal EN/DE UI language layer with a switcher that
defaults from account/browser locale, persists, and is independent of the research country, and internal
cached free-text translation (`mig_313` `fn_text_translations`) that shows a genuine translation when one
exists and the original otherwise. No new paid translation services, no provider calls, no rebuild.
Backend selftest 4/4; frontend 306/306; published to globalintelligenceactions.com and bundle-verified.
Status: PASS (18-market + EN/DE i18n + DE→EN on real data, bundle-verified) / PARTIAL (signed-in visual;
German coverage of some strings; free-text translation beyond seeded data needs an approved path).**

## 1. All 18 markets in the selector (req 2, 3) — reused, not rebuilt
The Explorer market selector now lists all **18 ecommerce-eligible countries** — AT, AU, BE, CA, CH, DE,
ES, FR, GB, HK, IE, IT, MY, NL, PH, PL, SG, US — from the EXISTING authoritative contract
`fn_ecommerce_supported_markets()` (country_name, currency, `research_supported`, `provider_coverage`
per category with states AVAILABLE / UNSUPPORTED_MARKET / BLOCKED_EXTERNAL_APPROVAL). Each market is
annotated with its discovery product count from `fn_product_explorer_markets()`; **empty markets stay
selectable** and land on the existing honest empty state ("No FastMoss discovery products for {market}
yet…"). An "advertising not supported here" hint surfaces where `provider_coverage` ADVERTISING ≠
AVAILABLE. Country isolation is unchanged — selecting a market drives `?country=` and every RPC passes it.
Today only GB (28) and DE (9) hold data; the other 16 render honest NO_DATA.

## 2. Internal UI language (req 4, 5, 6) — EN + DE
- New `LanguageProvider` + `useT()` + `LanguageSwitcher` (no heavy dependency; no prior i18n existed).
  Two complete dictionaries authored: **English and German**; structure allows adding the other market
  languages (nl/es/fr/it/pl) as config later.
- **Default language**: stored choice → account locale → `navigator.language` mapped to a supported
  language (de→de, else en). **Persisted** in `localStorage` (`strateloq.lang`). **Independent of the
  research country**: the language layer never reads or writes `?country=`; changing country never
  changes language and vice-versa.
- Translated via the dictionary: filter tabs, sorts, section titles, lifecycle / evidence-family / state
  / decision / opportunity-class / lane labels, and status/empty messages ("Not researched", "Not
  available in this market", "Evidence access blocked", "No competitor prices observed…", "Reference
  only", "No image", stale/seen lines, etc.). Numbers, currency and dates are formatted with Intl in the
  selected locale — **values, prices, counts, SKUs and provenance are never changed**.

## 3. Internal cached free-text translation (req 4, 6, 7) — `mig_313`
- `text_translation_cache` + `fn_text_translations(target_lang, texts[])` (`pulse_text_translations_v1`):
  a shared internal dictionary keyed by the exact source text + target language. A source string with no
  cached entry returns no translation, so the client keeps the **original** (never fabricated). No
  tenant/pricing/identity data; originals never mutated. auth-gated; selftest **4/4**.
- Seeded with genuine **German→English** translations for the real DE-market product titles (brand,
  model numbers, trademark marks and numeric values preserved verbatim) — e.g. "Ninja DualZone
  XL-Heißluftfritteuse mit 9,5 l Fassungsvermögen und 2 Schubladen – Grau" → "Ninja DualZone XL air
  fryer with 9.5 L capacity and 2 drawers – Grey".
- Frontend `useTextTranslations` + `resolveDisplayText`: with UI language English, DE-market German
  titles show their English translation with a "Translated" badge and the original retained; with UI
  language German they show the original German; GB (already English) titles are unchanged either way.
  Translation is exact-match only; brand/SKU/model/numbers are not altered by the client.

## 4. Preserved (req 3, 6; prior stages)
Product identity, brand, SKU, variants, numeric metric values, evidence provenance, REFERENCE_ONLY media,
Product Asset Lock (`concreteProductActionsAllowed={false}`), all five evidence families, the hero-image
fix and the evidence "Not researched" fix, tenant + country isolation. No paid calls, no provider
research, no architecture rebuild.

## 5. Verification
- **Backend**: `fn_text_translations_selftest` 4/4 (language gate, DE→EN hit, miss-keeps-original,
  unauth fail-closed). `mig_313` committed + deployed.
- **Frontend**: 306/306 tests (48 files), `tsc --noEmit` + build clean; new tests cover language
  switch + localStorage persistence, locale default, the 18-market selector (all 18, empty selectable),
  DE title → EN when lang=en / original when lang=de, untranslated-keeps-original, numeric values
  unchanged, decoders fail closed.
- **Live (bundle-verified on globalintelligenceactions.com)**: `fn_ecommerce_supported_markets`,
  `fn_text_translations`, `strateloq.lang`, the "Translated" badge, and the German dictionary strings
  (Produkte / Sprache / Nicht recherchiert / Alle / Bestseller) are all present; and the prior features
  (`fn_product_explorer`, ad/competitor contracts, hero image, "Not researched", Asset Lock) remain — no
  regression.

## Status: PASS (18-market + EN/DE i18n + DE→EN on real data) / PARTIAL
### Remaining / caveats
1. **Signed-in visual verification** — this environment cannot hold a founding-member session; the
   pixel-level multilingual experience (language switch, DE-market translated titles, all-18 selector)
   must be confirmed by a signed-in member. **Not claimed as visual PASS.**
2. **German string coverage** — EN is complete; a few panel-only status / server-built summary strings
   fall back to English where a German entry is not yet authored (honest fallback, never a wrong
   translation).
3. **Free-text translation scalability** — titles/descriptions are translated from an internal cache
   seeded for the current real data. Translating NEW/unseen free-text at scale needs an approved
   translation path (the cache + lookup is the reusable mechanism); until then unseen free-text shows the
   original with its language preserved. No paid translation service was added, per instruction.
4. Languages beyond EN/DE (nl/es/fr/it/pl for the other markets) are structurally ready but not yet
   authored.
