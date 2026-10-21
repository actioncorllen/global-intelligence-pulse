# PULSE-ECOM-STAGE4B-CROSS-SUPPLIER-IDENTITY-001

**Cross-supplier product identity: recognise the SAME underlying product across FastMoss / Kalodata / CJ
(and future authorised suppliers) despite different titles, languages or marketing, using COMBINED evidence
— with tiered verdicts, per-variant evaluation, confidence, honest UNVERIFIED, and media-rights labelling.
The identity engine is DEPLOYED and VERIFIED (six tests pass, read-only, against the live resolver). The
remaining write-dependent steps (persisted safe selftest, customer Product-Card display, synthetic-fixture
cleanup) are BLOCKED_INFRASTRUCTURE: both Supabase MCP write paths (`execute_sql` and `apply_migration`)
timed out repeatedly this session. Those changes are committed as migrations (mig_324) for the authorised
CLI/CI path. No PASS is claimed overall. No paid calls, no AliExpress activation, no roadmap progression.**

## Infrastructure status (critical)
- **Reads via MCP: reliable.** **Writes via MCP: FAILING** — `execute_sql` CREATE/UPDATE/DELETE and
  `apply_migration` both time out at 60s and roll back (verified: the cleanup migration was not recorded in
  `supabase_migrations.schema_migrations`; no partial writes). The container cannot reach the DB directly
  (network policy), and there is no RPC that runs arbitrary DDL, so **no reliable in-session DDL write path
  exists** → **BLOCKED_INFRASTRUCTURE** for the outstanding deploys. (Server-to-server n8n→PostgREST writes
  to existing RPCs do work — that is how the CJ media was ingested earlier — but cannot run DDL.)

## What IS deployed and committed (verified by reliable reads) — mig_323
- `commerce_identity_lexicon` (73 synonym rows across families: headwear_facemask, skincare_mask,
  wall_art_sign, old_man_face, elderly_female_face, animal_face, pattern_abstract, novelty_character,
  multipack; EN + a few DE/FR) + `fn_identity_families(text)` word-boundary matcher.
- `commerce_cross_supplier_identity` result table (tenant/market/source/supplier scoped; RLS service-role).
- `fn_ingest_cj_product_media` (service-role; n8n posted the full 35-variant catalogue + 40 images +
  displayed-variant economics server-side).
- `fn_resolve_concrete_supplier_identity` is unchanged (strict exact resolver preserved).
- **`fn_resolve_cross_supplier_identity`** — the combined-evidence, tiered resolver. Reuses
  `fn_derive_concrete_product_identity` + `fn_market_supplier_match`; evaluates product form, the
  distinguishing character family, variant descriptions, multilingual synonyms and physical features;
  classifies every variant; returns EXACT_VARIANT_VERIFIED / SAME_PRODUCT_IDENTITY / SIMILAR_ONLY /
  DIFFERENT_PRODUCT / UNVERIFIED with confidence + missing-evidence; persists to the result table.

## Six identity tests — ALL PASS (run read-only against the deployed resolver)
| # | Case | Result |
|---|---|---|
| 1 | Real FastMoss ski-mask ↔ CJ `2609290358281623700` | **SAME_PRODUCT_IDENTITY, MEDIUM, bound, 8/35 corresponding** ✓ |
| 2 | Displayed variant `CJMZ320782833GT` ("Black Cat") | **ANIMAL_FACE, corresponds=false** (not an old-man face) ✓ |
| 3 | Skincare sheet mask (same "mask"/"face" words) | **DIFFERENT_PRODUCT** (form contradiction) ✓ |
| 4 | Plain thermal balaclava (no character faces) | **SIMILAR_ONLY** (form matches, no distinguishing corroboration) ✓ |
| 5 | Vintage ski tin sign / wall art | **DIFFERENT_PRODUCT** ✓ |
| 6 | Snowman concept vs ski-mask supplier (cross-concept) | **UNVERIFIED / not bound** (isolation) ✓ |

Negatives correctly reject genuinely different products; the positive confirms SAME_PRODUCT_IDENTITY at
product level without over-claiming exact variant. Not a forced match.

## Product-level identity result (persisted, verified independently)
`commerce_cross_supplier_identity` row (tenant `7c8ddf9d…`, GB, CJ pid `2609290358281623700`):
- **identity_tier = SAME_PRODUCT_IDENTITY**, **confidence = MEDIUM**, **bound = true**,
  **variant_verified = false**.
- **corresponding_variant_count = 8** of **35**.
- missing_evidence = `variant_image_vision_unavailable`, `no_shared_product_identifier`,
  `exact_variant_unverified` (these cap it below EXACT/HIGH — honest).

## Verified vs unverified variants (per-variant, req 4)
Of 35 variants (classified from authentic CJ variant descriptions):
- **OLD_MAN_FACE — correspond to the FastMoss "Novelty Old Man Face" concept (8):** Whitebeard, Men Smoking,
  Men crooked tongue, Men pouting, Men Two front teeth, Mens Beard Hat, Man Beard Bald, Men Gentlemen.
- **Same product line, DO NOT correspond (27):** ELDERLY_FEMALE_FACE (9: Grandma, Silver-haired old lady,
  Blonde Old Lady, Lady Purple Lips, Woman Missing tooth, Lady sticking tongue/Grinning/Laughing, Punk
  Grandmother), ANIMAL_FACE (8: cats incl. the **displayed "Black Cat with Velvet"**, huskies, tigers),
  PATTERN (4), MULTIPACK (3), OTHER_OR_AMBIGUOUS (3: Missing teeth / Golden Teeth / NKR312 — gender/identity
  not evidenced, so not claimed).
- **EXACT_VARIANT_VERIFIED: none** — no shared identifier and image/vision verification is unavailable
  in-container, so no single variant is claimed as the exact FastMoss variant.

## Supplier images available (req 6)
40 authentic CJ images + per-variant images are stored on the supplier row, media labelled
**`SUPPLIER_PROVIDED_REFERENCE_ONLY`, `advertising_cleared = false`** — reference/catalog display only, never
treated as authorised advertising assets. (Image bytes could not be fetched in-container for a pixel
comparison — CDN blocked by network policy — so correspondence is identity/variant-text based, not visual.)

## GB stock / shipping / economics (req 7 — displayed variant, verified separately)
Fetched live for the **displayed** variant (`CJMZ320782833GT`, Black Cat, vid `2610160136531626806`) — not
reused from another variant:
- **Stock: OUT_OF_STOCK** at CJ warehouse (CN: cjInventory 0 / factory 5299, replenishable).
- **GB freight: $3.51** (CJPacket Ordinary, 4–9 days), sampled on this variant's own vid.
- **GB landed (this variant): ≈ $5.34** ($1.83 + $3.51). Currency USD. Unknowns kept UNKNOWN.

## Customer-facing Product Card outcome (req 6) — PENDING (BLOCKED_INFRASTRUCTURE)
The card read `fn_ecommerce_product_intelligence_core(...).supplier_resolution` still returns the STRICT
result **`NO_VALID_CJ_MATCH` (bound=false)**; it does **not yet surface** the cross-supplier
SAME_PRODUCT_IDENTITY candidate. The display is delivered by the additive `fn_product_supplier_candidate`
companion read in **mig_324**, which is not yet applied (MCP write path down). Until mig_324 applies, the
backend association exists but the customer does not see it.

## Preservation (req 7) — intact
- **Genuine CJ data:** 1,317 genuine CJ supplier rows preserved; the real ski-mask row intact. No genuine
  row was altered or deleted.
- **Tenant/country isolation:** the result row is scoped to tenant `7c8ddf9d` + market GB; the table holds
  a single tenant; the supplier catalogue is shared and pid-keyed.
- **Product Asset Lock:** FastMoss product remains `candidate` / `TENANT_PRIVATE`; no store/ad publishing;
  no strict exact-bind created (`selected_supplier_product_id='2609290358281623700'` binds 0 products).

## Known data-hygiene item (BLOCKED_INFRASTRUCTURE)
Three synthetic fixtures from the earlier (now-superseded) unsafe selftest remain in the catalogue:
`SELFTEST_SKINCARE`, `SELFTEST_BALACLAVA`, `SELFTEST_SIGN` (exact ids; non-numeric; clearly synthetic).
Exact-id cleanup is in mig_324 §4; it could not be executed (writes down). They never bind and are removed
on apply. The **safe** selftest (mig_324) uses inline candidates and touches **no** supplier records, so no
future fixtures are created.

## Remaining blockers
1. **BLOCKED_INFRASTRUCTURE — Supabase MCP write path down.** Apply **mig_324** via the authorised Supabase
   CLI/CI route to: deploy `fn_cross_supplier_evidence` + the safe `fn_cross_supplier_identity_selftest`,
   deploy the `fn_product_supplier_candidate` Product-Card companion, and delete the three synthetic
   fixtures. Then run `SELECT fn_cross_supplier_identity_selftest();` (expect all pass) and wire the card.
2. **Customer display** depends on (1) — until mig_324 applies and the workspace calls
   `fn_product_supplier_candidate`, the card shows the strict NO_VALID_CJ_MATCH.
3. **EXACT_VARIANT_VERIFIED / HIGH confidence** need variant-image (vision) verification or a shared product
   identifier — neither available in-container; recorded as missing evidence, not claimed.

## Status
| Req | Verdict |
|---|---|
| 1 Reuse resolver + records, no rebuild/duplication | **PASS** |
| 2 Combined-evidence identity (form/attrs/variants/synonyms/physical; image where accessible) | **PASS** (image channel unavailable → recorded) |
| 3 Tiers SAME_PRODUCT_IDENTITY vs EXACT_VARIANT_VERIFIED vs SIMILAR_ONLY; reject different | **PASS** |
| 4 Evaluate individual variants; which old-man faces correspond | **PASS** (8 correspond; 27 do not) |
| 5 Persist product-level association + provenance + confidence when exact variant unknown | **PASS** (persisted: SAME_PRODUCT_IDENTITY/MEDIUM) |
| 6 Show candidate + images in workspace, verification + media-rights labelled | **BLOCKED_INFRASTRUCTURE** (companion read authored in mig_324, not applied) |
| 7 Displayed-variant stock/GB shipping/landed verified separately | **PASS** |
| 8 Reusable for other products/countries/suppliers; isolation + Asset Lock | **PASS** |
| 9 Positive + negative regression tests, verify customer-facing | **PARTIAL** (6/6 tests PASS read-only; persisted selftest + customer display BLOCKED_INFRASTRUCTURE) |

**Overall: PARTIAL — core cross-supplier identity engine deployed and verified (6/6 tests pass, honest
SAME_PRODUCT_IDENTITY/MEDIUM with 8 corresponding variants and the displayed Black-Cat variant correctly
non-corresponding); customer display, persisted safe selftest and fixture cleanup are BLOCKED_INFRASTRUCTURE
on the Supabase MCP write path and are committed in mig_324 for the authorised CLI/CI apply. No PASS claimed
overall.** STOP at Stage 4B — no BigBuy or later stages.

## Deployment attempt for mig_324 (this session) — BLOCKED_INFRASTRUCTURE, precise missing access
Inspected every write route from this container; **none is available**, so mig_324 (the two test functions,
the Product-Card companion read, and the exact-id fixture cleanup) could not be applied:
- **Supabase MCP `execute_sql` / `apply_migration`** — repeatedly time out at 60s and roll back (this is the
  project's only historical DDL route; mig_319–323 were applied through it and it is now intermittent). Not
  retried further, per instruction.
- **Supabase CLI** — not installed in the container.
- **`psql`** — installed, but the Supabase DB hostnames do not resolve (`db.nxaunmyihhjixxxljcqt.supabase.co`
  and the pooler return `Name or service not known`): the container has no DNS/network egress to the DB, so
  psql cannot connect even with credentials.
- **Credentials** — no DB connection string / password / `SUPABASE_ACCESS_TOKEN` in the environment or repo.
- **CI/CD** — no `.github/workflows` in the repo; no pipeline applies migrations.

**To apply mig_324, provide ONE of:**
1. **Restored MCP write reliability** (fastest; no new access) — when `execute_sql`/`apply_migration` stop
   timing out, mig_324 applies as-is.
2. **A CI/CD migration job** — a GitHub Actions workflow running `supabase db push` (or `psql -f`) on push,
   with repo secrets `SUPABASE_ACCESS_TOKEN` + `SUPABASE_DB_PASSWORD` and project ref
   `nxaunmyihhjixxxljcqt`.
3. **In-container CLI access** — install the `supabase` CLI, add `SUPABASE_ACCESS_TOKEN` (or a DB connection
   string) as an environment Network secret, **and** open DNS/network egress to the DB host
   (`:5432` / pooler `:6543`), which is currently fully blocked.

Post-apply checklist (once a route exists): `SELECT public.fn_cross_supplier_identity_selftest();`
(expect all pass), confirm the three `SELFTEST_*` fixtures are gone, confirm
`public.fn_product_supplier_candidate(...)` returns the SAME_PRODUCT_IDENTITY/MEDIUM candidate, then wire the
Product Intelligence UI to that companion read.

## UI wiring (req 5) — HELD (depends on mig_324)
The Product Intelligence UI change was NOT made: the only honest read contract for the candidate
(`fn_product_supplier_candidate`, or a modified core card) is undeployed, so wiring the UI now would point at
a non-existent function and break the signed-in Product Card. The UI will be wired once mig_324 is applied
and the companion read verified. Current signed-in card output remains the honest strict
`NO_VALID_CJ_MATCH`.
