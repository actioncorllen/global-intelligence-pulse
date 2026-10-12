# STAGE 1 — FastMoss Product-Native COMMERCE Discovery Adapter (2nd provider)

**Date:** 2026-10-12 · **Project:** nxaunmyihhjixxxljcqt (live prod) · **Branch:** claude/cool-faraday-kgudh1
**Scope:** Add FastMoss as a SECOND independent product-native provider in the existing COMMERCE lane,
reusing the Kalodata-established patterns (secret broker, nonce trigger, normalized contract, product-native
gate, explicit lane outcomes, auto_fresh_discovery bridge). No redesign. Stage 2 NOT started.

## 1. Capability gap closed
COMMERCE had one product-native provider (Kalodata). FastMoss New Listed = early/new product-native
discovery, added as an independent second provider: FastMoss DISCOVERS early candidates; Kalodata gives
product-native + momentum evidence; Strateloq qualifies. A FastMoss result never auto-qualifies.

## 2. Files / migrations
- `mig_378a_fastmoss_market_config.sql` — 20 documented FastMoss regions (data-driven; IE excluded).
- `mig_378b_fastmoss_request_screens_plan.sql` — `fn_fastmoss_discovery_request` (derived date),
  `fn_is_branded_or_ip_sensitive`, `fn_fastmoss_record_lane_outcome`, multi-lane plan v3 (additive
  `commerce_providers` exposing Kalodata + FastMoss).
- `mig_378c_fastmoss_ingest.sql` — `fn_fastmoss_ingest_candidates` (normalize + gate + branded/IP screen
  + provider-id dedup + family correlation + seller evidence + auto-dispatch).
- `mig_378d_fastmoss_invoke_orchestrator.sql` — `fn_fastmoss_run_discovery` (shared capability-nonce trigger).
- `mig_378e_fastmoss_commerce_adapter_selftest.sql` — 18-invariant regression.
- `supabase/functions/fastmoss-discovery/index.ts` — secure broker (ACTIVE v1; Bearer auth; nonce +
  service-role gated; fail-closed; redacting).

## 3. FastMoss provider contract
`POST https://openapi.fastmoss.com/product/v1/rank/newListed`, `Authorization: Bearer <client_secret>`.
Seed-free body: `{filter:{region, date_info:{type:"day", value:<yesterday UTC, derived>}}, orderby:[{field:"day3_units_sold", order:"desc"}], page:1, pagesize:10}`. `date_info.value` is derived (completed provider day), never hardcoded.

## 4. Security/secret status
`FASTMOSS_CLIENT_SECRET` lives only in the Edge Function env (same pattern as Kalodata). Never in DB rows,
frontend, logs, errors, migrations, tests, or fixtures. Broker is service-role/nonce-gated and fail-closed.
**Backend probe: `secret_present = false` — the secret is NOT installed.**

## 5. Market-support configuration (data-driven)
20 FastMoss regions supported+enabled: US, ID, GB, VN, TH, MY, PH, SG, ES, MX, DE, FR, PT, NL, BE, AT, PL,
IT, BR, JP. **IE → UNSUPPORTED_MARKET** (not a documented FastMoss region), never substituted; country
isolation enforced. Provider-specific, not Strateloq's 18-market list.

## 6. Normalization mapping (existing discovery contract; UNKNOWN→NULL)
product_id→provider id/dedup key · title→product_identity · region→market · real_price→price/observed_price ·
day3_units_sold→sales_units (short window) · day3_gmv→revenue (short window) · total_units_sold/total_gmv/
commission_rate→provider evidence · seller_id/shop.name/shop.total_units_sold→seller evidence (separate) ·
category→provider category evidence · cover→reference media only (never qualification) · **launch_time→RAW
only (`launch_time_raw`), NEVER authoritative first_seen** (first_seen stays NULL).

## 7. Identity / dedup / IP handling
Provider record ≠ product identity ≠ seller ≠ concrete product ≠ supplier SKU. Idempotent dedup by
`fastmoss_product_id`; country-isolated normalized-family correlation (`product_family_key`+market) merges
substantially-identical records into ONE product while keeping each seller as separate evidence (not
title-only); cross-provider-ready via the shared family key. Branded/IP (Pokémon, Reisenthel, …) →
`BRANDED_OR_IP_REVIEW`, held from auto-dispatch (fail closed to review). Correlation/cross-provider
agreement enriches evidence only — never auto-qualifies.

## 8. Regression results
`fn_fastmoss_commerce_adapter_selftest` = **18/18 all_pass** (dry-run + introspection, no live quota).
Check 18 confirms existing suites still green: Kalodata 17/17, multi-lane 16/16, research bridge 8/8,
Stage-1 invariants 8/8, image independence 10/10, autonomous 12/12.

## 9. Real production-path result
**BLOCKED_EXTERNAL_SECRET** — `FASTMOSS_CLIENT_SECRET` not installed; no live call made (broker
fail-closed). Install it, then one bounded DE call runs the full path (DE → New Listed → normalized →
identity/dedup → eligibility → survivors → auto_fresh_discovery → deep research → concrete resolution →
opportunity evaluation).

## 10. Provider usage / calls consumed
**0 live FastMoss calls** (regression is fixture/dry-run; only a safe secret probe that returns before any
provider call). Trial quota untouched.

## 11. FASTMOSS ADAPTER verdict
**PASS_FASTMOSS_COMMERCE_ADAPTER** — production contract implemented, deployed (fail-closed), and
18/18 tested on every internally controllable surface. The only unexecuted step is the live call, gated
solely by the missing backend secret.

## 12. OVERALL STAGE 1 verdict
**BLOCKED_STAGE_1_PRODUCT_OPPORTUNITY_INTELLIGENCE** — no genuinely newly discovered product has reached
CONCRETE_RESOLVED + benchmark-qualified. (The Kalodata real DE run discovered real products end-to-end but
all evaluated WATCH/INSUFFICIENT; FastMoss live run is blocked on its secret.)

## 13. Exact remaining blocker
Install **`FASTMOSS_CLIENT_SECRET`** at **Supabase → Project `nxaunmyihhjixxxljcqt` → Project Settings →
Edge Functions → Manage secrets** (or `supabase secrets set FASTMOSS_CLIENT_SECRET=<key> --project-ref
nxaunmyihhjixxxljcqt`). Optional override `FASTMOSS_BASE_URL`. Then one bounded DE call completes live
verification. Stage-1 PASS additionally requires a discovered product to clear local-market evidence +
qualification to CONCRETE_RESOLVED (unchanged thresholds).
