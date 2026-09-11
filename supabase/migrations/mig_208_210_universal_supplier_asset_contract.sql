-- FOUNDER ADDENDUM — UNIVERSAL SUPPLIER PRODUCT ASSET CONTRACT (permanent, provider-independent)
-- Deployed to Supabase project nxaunmyihhjixxxljcqt as:
--   mig_208  supplier_product_assets (canonical SOURCE_PRODUCT_ASSET store — every supplier adapter writes here)
--   mig_209  fn_ingest_supplier_product_assets (provider-independent normalizer; CJ first)
--   mig_210  fn_resolve_product_image v2 (sources primary from canonical assets; 2-layer identity)
-- Rules encoded:
--   * A supplier product's OWN images are canonically EXACT to that supplier product
--     (asset_identity=SUPPLIER_OWN) with NO fuzzy matching — ingested at product-import time, not later.
--   * Representing an independently-discovered demand candidate as EXACT still requires a real identifier
--     link (fn_resolve_product_image p_exact_link) — a category/title/same-store match is never EXACT, so a
--     comparable image can never masquerade as the exact candidate (hero_eligible=false).
--   * Source assets are strictly separate from GENERATED_MARKETING_ASSET (media_assets) and
--     COMPETITOR_REFERENCE_ASSET; competitor creative is never a hero.
--   * Missing gallery/variant/video are recorded as IMAGE_UNAVAILABLE with a reason — never fabricated,
--     never borrowed from another supplier or a competitor.
--   * Original supplier URL + rights + provenance preserved for later caching into Pulse object storage;
--     the Claude sandbox/CDN block is a Claude-only limitation and never shapes this production store.
--   * Provider-independent: CJdropshipping is the first adapter; future EU/AliExpress/wholesaler/
--     manufacturer/marketplace adapters normalize into the same table and functions unchanged.
-- Acceptance flags per product: PRODUCT_HAS_IMAGE / IMAGE_RESOLVED_BY_PULSE / IMAGE_RENDERABLE_IN_PULSE /
--   IMAGE_RENDER_BLOCKED_ONLY_IN_CLAUDE. SECURITY DEFINER, search_path='', REVOKE'd from PUBLIC/anon.

CREATE TABLE IF NOT EXISTS public.supplier_product_assets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  supplier text NOT NULL, supplier_product_id text NOT NULL, supplier_variant_id text, product_title text,
  asset_type text NOT NULL, asset_class text NOT NULL DEFAULT 'SOURCE_PRODUCT_ASSET',
  asset_identity text NOT NULL DEFAULT 'SUPPLIER_OWN', rights_state text NOT NULL DEFAULT 'UNKNOWN',
  availability text NOT NULL DEFAULT 'AVAILABLE', unavailable_reason text, source_url text, original_source text,
  is_primary boolean NOT NULL DEFAULT false, cache_state text NOT NULL DEFAULT 'ORIGIN_HOTLINK', storage_ref text,
  observed_at timestamptz, provenance jsonb NOT NULL DEFAULT '{}'::jsonb, is_fixture boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS idx_spa_product ON public.supplier_product_assets (supplier, supplier_product_id);
CREATE INDEX IF NOT EXISTS idx_spa_primary ON public.supplier_product_assets (supplier, supplier_product_id, is_primary);
ALTER TABLE public.supplier_product_assets ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.supplier_product_assets FROM PUBLIC, anon;

-- fn_ingest_supplier_product_assets(p_supplier_row uuid, p_persist): reads a commerce_supplier_products
--   row, writes PRIMARY_IMAGE (SUPPLIER_OWN, SUPPLIER_PROVIDED for CJ) + GALLERY/VARIANT/VIDEO where the
--   source exposes them else an IMAGE_UNAVAILABLE row w/ reason. Returns the four acceptance flags.
-- fn_resolve_product_image(p_tenant, p_product, p_supplier, p_persist, p_exact_link): ingests canonical
--   assets, sources the primary image, layers candidate identity (EXACT only with p_exact_link; else fuzzy
--   fn_resolve_supplier_identity), hero_eligible = EXACT + usable rights; persists product_asset_intelligence.
--   Full bodies deployed in the database (mig_209, mig_210c).

-- Acceptance (manual, real, NOT published): 5+ real CJ products ingested — each PRIMARY_IMAGE present
--   (SUPPLIER_OWN/EXACT to supplier product, real URL, rights SUPPLIER_PROVIDED); gallery/variant recorded
--   IMAGE_UNAVAILABLE w/ reason (source cache lacks them). Discovered candidates (projector, frame) resolve
--   to CLOSE_COMPARABLE, hero_eligible=false; the EXACT hero path activates only with a real identifier link.
--   Flags: PRODUCT_HAS_IMAGE=true, IMAGE_RESOLVED_BY_PULSE=true, IMAGE_RENDERABLE_IN_PULSE=true,
--   IMAGE_RENDER_BLOCKED_ONLY_IN_CLAUDE=true. 14/14 tests PASS. No customer publication; media_assets
--   untouched; campaign_activation=FALSE; advertising_spend=0.
