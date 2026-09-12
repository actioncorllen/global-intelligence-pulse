-- PULSE-ECOM-P8-STOREFRONT-RUNTIME-INTEGRATION-001
-- Registry for the LOCKED Universal Conversion Template System (P8 contract
-- PULSE-ECOM-P8-UNIVERSAL-CONVERSION-TEMPLATES-001 sections 5, 6, 7). Reference
-- data only (not tenant-scoped): the 8 locked template families, the 22 approved
-- section types, and the 7 hero variants. RLS on; readable by authenticated;
-- writable by service_role only. Additive — no change to existing Phase-8 tables.

-- ---------------------------------------------------------------------------
-- 1. Section-type registry (22 approved sections, P8 §5)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.conversion_section_types (
  section_type text PRIMARY KEY,
  default_conversion_role text NOT NULL,
  required_evidence text[] NOT NULL DEFAULT '{}',   -- evidence keys that must exist or the section hides/degrades
  structural boolean NOT NULL DEFAULT false,        -- structural/text sections never fabricate factual claims
  mobile_defaults jsonb NOT NULL DEFAULT '{}'::jsonb,
  description text,
  version text NOT NULL DEFAULT 'v1'
);

-- ---------------------------------------------------------------------------
-- 2. Hero-variant registry (7 hero variants, P8 §6 hero strategies)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.conversion_hero_variants (
  variant text PRIMARY KEY,
  media_kind text NOT NULL,           -- IMAGE | VIDEO | LIFESTYLE | UGC
  required_evidence text[] NOT NULL DEFAULT '{}',
  description text,
  version text NOT NULL DEFAULT 'v1'
);

-- ---------------------------------------------------------------------------
-- 3. Template-family registry (8 locked families, P8 §6)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.conversion_template_families (
  family text PRIMARY KEY,
  use_case text NOT NULL,
  categories text[] NOT NULL DEFAULT '{}',
  traffic_fit text[] NOT NULL DEFAULT '{}',
  required_sections text[] NOT NULL DEFAULT '{}',
  optional_sections text[] NOT NULL DEFAULT '{}',
  excluded_sections text[] NOT NULL DEFAULT '{}',
  hero_variant text NOT NULL REFERENCES public.conversion_hero_variants(variant),
  ordering_strategy text[] NOT NULL DEFAULT '{}',   -- canonical recommended section order
  evidence_requirements text[] NOT NULL DEFAULT '{}',
  disqualifiers text[] NOT NULL DEFAULT '{}',
  cta_structure jsonb NOT NULL DEFAULT '{}'::jsonb,
  selection_priority int NOT NULL DEFAULT 100,      -- deterministic tie-break (lower = preferred)
  is_active boolean NOT NULL DEFAULT true,
  version text NOT NULL DEFAULT 'v1'
);

ALTER TABLE public.conversion_section_types     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.conversion_hero_variants     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.conversion_template_families ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  -- readable by any authenticated tenant (shared, non-private reference data)
  IF NOT EXISTS (SELECT 1 FROM pg_policy WHERE polname='cst_select_all') THEN
    CREATE POLICY cst_select_all ON public.conversion_section_types FOR SELECT TO authenticated USING (true);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policy WHERE polname='cst_service_all') THEN
    CREATE POLICY cst_service_all ON public.conversion_section_types FOR ALL TO service_role USING (true) WITH CHECK (true);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policy WHERE polname='chv_select_all') THEN
    CREATE POLICY chv_select_all ON public.conversion_hero_variants FOR SELECT TO authenticated USING (true);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policy WHERE polname='chv_service_all') THEN
    CREATE POLICY chv_service_all ON public.conversion_hero_variants FOR ALL TO service_role USING (true) WITH CHECK (true);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policy WHERE polname='ctf_select_all') THEN
    CREATE POLICY ctf_select_all ON public.conversion_template_families FOR SELECT TO authenticated USING (true);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policy WHERE polname='ctf_service_all') THEN
    CREATE POLICY ctf_service_all ON public.conversion_template_families FOR ALL TO service_role USING (true) WITH CHECK (true);
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- Seed: 22 section types (P8 §5). required_evidence drives fail-closed behavior.
-- ---------------------------------------------------------------------------
INSERT INTO public.conversion_section_types (section_type, default_conversion_role, required_evidence, structural, mobile_defaults, description) VALUES
 ('HERO','capture_attention','{}',                          false, '{"priority":1}',                'Above-the-fold promise; must not invent claims beyond product evidence'),
 ('PRODUCT_GALLERY','show_product','{PRODUCT_IMAGE}',        false, '{"priority":2,"lazy":true}',    'Multiple product images; requires rights-clear supplier images'),
 ('PRODUCT_VIDEO','show_product','{VIDEO_ASSET}',            false, '{"priority":2,"lazy":true}',    'Product video; requires a usable video asset'),
 ('PROBLEM','frame_pain','{BUYER_PAIN}',                     true,  '{"priority":3}',                'States the buyer problem; requires a legitimate articulable pain'),
 ('SOLUTION','present_solution','{}',                        true,  '{"priority":3}',                'Positions the product as the solution'),
 ('BENEFITS','persuade','{}',                                true,  '{"priority":4}',                'Benefit bullets supported by product evidence; editable'),
 ('FEATURE_GRID','inform','{PRODUCT_SPECS}',                 false, '{"priority":4}',                'Feature grid; requires known product features/specs'),
 ('HOW_IT_WORKS','reduce_friction','{}',                     true,  '{"priority":5}',                'Step-by-step usage; editable'),
 ('VISUAL_DEMO','demonstrate','{DEMO_ASSET}',               false, '{"priority":3}',                'Show-it-working; requires a usable demo/video asset'),
 ('BEFORE_AFTER','demonstrate','{BEFORE_AFTER_EVIDENCE}',    false, '{"priority":5}',                'Before/after; renders ONLY with genuine before/after evidence'),
 ('SPECIFICATIONS','inform','{PRODUCT_SPECS}',               false, '{"priority":6}',                'Spec table; requires known specifications'),
 ('COMPARISON','differentiate','{COMPARISON_BASIS}',         false, '{"priority":6}',                'Vs-alternatives; factual, non-deceptive claims only'),
 ('SOCIAL_EVIDENCE','build_trust','{REVIEWS_OR_UGC}',        false, '{"priority":5}',                'Reviews/UGC; renders ONLY with real rights-cleared social proof'),
 ('OFFER','convert','{GENUINE_OFFER}',                       false, '{"priority":7}',                'Offer/bundle; scarcity/discount render ONLY when genuine'),
 ('PRICE','convert','{}',                                    true,  '{"priority":7}',                'Price block; no fake crossed-out price without verified prior price'),
 ('VARIANTS','configure','{}',                               true,  '{"priority":7}',                'Variant selector'),
 ('SHIPPING','reduce_friction','{}',                         true,  '{"priority":8}',                'Shipping estimate; labeled estimate, never guaranteed'),
 ('RETURNS','build_trust','{RETURNS_POLICY}',                true,  '{"priority":8}',                'Returns policy; only stated when a real policy exists'),
 ('TRUST','build_trust','{}',                                true,  '{"priority":8}',                'Honest trust copy; no fabricated certifications/warranty'),
 ('FAQ','reduce_friction','{}',                              true,  '{"priority":9}',                'FAQ; factual, editable'),
 ('STICKY_ADD_TO_CART','convert','{}',                       true,  '{"priority":10,"sticky":true}', 'Mobile sticky CTA'),
 ('FINAL_CTA','convert','{}',                                true,  '{"priority":11}',               'Closing call to action')
ON CONFLICT (section_type) DO UPDATE SET
  default_conversion_role=EXCLUDED.default_conversion_role, required_evidence=EXCLUDED.required_evidence,
  structural=EXCLUDED.structural, mobile_defaults=EXCLUDED.mobile_defaults, description=EXCLUDED.description;

-- ---------------------------------------------------------------------------
-- Seed: 7 hero variants
-- ---------------------------------------------------------------------------
INSERT INTO public.conversion_hero_variants (variant, media_kind, required_evidence, description) VALUES
 ('HERO_PROBLEM_FRAMING','IMAGE','{}',                 'Problem-led hero framing the buyer pain'),
 ('HERO_VIDEO_DEMO','VIDEO','{DEMO_ASSET}',            'Video-first hero showing the product working'),
 ('HERO_LIFESTYLE','LIFESTYLE','{PRODUCT_IMAGE}',      'Aspirational lifestyle hero'),
 ('HERO_UGC','UGC','{REVIEWS_OR_UGC}',                 'Creator/authentic UGC hero (requires rights-cleared UGC)'),
 ('HERO_FEATURE_SPOTLIGHT','IMAGE','{PRODUCT_SPECS}',  'Spec/innovation spotlight hero'),
 ('HERO_COMPARISON','IMAGE','{COMPARISON_BASIS}',      'Comparison-led hero'),
 ('HERO_OFFER','IMAGE','{GENUINE_OFFER}',              'Offer/urgency hero (genuine offers only)')
ON CONFLICT (variant) DO UPDATE SET
  media_kind=EXCLUDED.media_kind, required_evidence=EXCLUDED.required_evidence, description=EXCLUDED.description;

-- ---------------------------------------------------------------------------
-- Seed: 8 locked template families (P8 §6)
-- ---------------------------------------------------------------------------
INSERT INTO public.conversion_template_families
 (family, use_case, categories, traffic_fit, required_sections, optional_sections, excluded_sections,
  hero_variant, ordering_strategy, evidence_requirements, disqualifiers, cta_structure, selection_priority) VALUES
 ('PROBLEM_SOLUTION','Pain-led problem solvers',
   '{health_gadget,home_fix,organization,kitchen}','{problem_aware_social,interest}',
   '{HERO,PROBLEM,SOLUTION,BENEFITS,HOW_IT_WORKS,PRICE,FINAL_CTA}',
   '{FAQ,TRUST,SHIPPING,SOCIAL_EVIDENCE}','{}',
   'HERO_PROBLEM_FRAMING',
   '{HERO,PROBLEM,SOLUTION,BENEFITS,HOW_IT_WORKS,TRUST,SHIPPING,PRICE,FAQ,FINAL_CTA}',
   '{BUYER_PAIN}','{no_articulable_problem}',
   '{"primary":"solution_oriented","secondary":"scroll_to_details"}', 20),
 ('VISUAL_DEMO','Show-it-working products',
   '{gadget,tool,cleaning,kitchen}','{video_social,tiktok,reels}',
   '{HERO,VISUAL_DEMO,HOW_IT_WORKS,BENEFITS,PRICE,STICKY_ADD_TO_CART,FINAL_CTA}',
   '{BEFORE_AFTER,FAQ,SHIPPING}','{}',
   'HERO_VIDEO_DEMO',
   '{HERO,VISUAL_DEMO,HOW_IT_WORKS,BENEFITS,SHIPPING,PRICE,FAQ,STICKY_ADD_TO_CART,FINAL_CTA}',
   '{DEMO_ASSET}','{no_usable_demo_asset}',
   '{"primary":"add_to_cart","sticky":true}', 30),
 ('PREMIUM_LUXURY','Design/quality-led premium goods',
   '{home_decor,accessory,premium}','{aspirational,brand}',
   '{HERO,PRODUCT_GALLERY,BENEFITS,SPECIFICATIONS,TRUST,PRICE,FINAL_CTA}',
   '{RETURNS,SOCIAL_EVIDENCE}','{OFFER,STICKY_ADD_TO_CART}',
   'HERO_LIFESTYLE',
   '{HERO,PRODUCT_GALLERY,BENEFITS,SPECIFICATIONS,TRUST,PRICE,RETURNS,FINAL_CTA}',
   '{PRODUCT_IMAGE,PRODUCT_SPECS}','{low_cost_commodity_no_premium_substantiation}',
   '{"primary":"understated"}', 50),
 ('UGC_SOCIAL_COMMERCE','Creator/authentic social proof',
   '{broad_consumer}','{ugc_creative,social}',
   '{HERO,SOCIAL_EVIDENCE,BENEFITS,HOW_IT_WORKS,PRICE,FINAL_CTA}',
   '{SHIPPING,FAQ}','{}',
   'HERO_UGC',
   '{HERO,SOCIAL_EVIDENCE,BENEFITS,HOW_IT_WORKS,PRICE,SHIPPING,FINAL_CTA}',
   '{REVIEWS_OR_UGC}','{no_legitimate_social_proof}',
   '{"primary":"add_to_cart"}', 40),
 ('FEATURE_TECHNOLOGY','Spec/innovation-led',
   '{electronics,tech_accessory}','{research,intent}',
   '{HERO,FEATURE_GRID,SPECIFICATIONS,HOW_IT_WORKS,BENEFITS,PRICE,FAQ,FINAL_CTA}',
   '{COMPARISON,PRODUCT_VIDEO}','{}',
   'HERO_FEATURE_SPOTLIGHT',
   '{HERO,FEATURE_GRID,SPECIFICATIONS,HOW_IT_WORKS,BENEFITS,COMPARISON,PRICE,FAQ,FINAL_CTA}',
   '{PRODUCT_SPECS}','{unknown_specs}',
   '{"primary":"add_to_cart","secondary":"see_specs"}', 25),
 ('COMPARISON_EVIDENCE','Why-this-vs-alternatives',
   '{considered_purchase,electronics,home}','{comparison,intent}',
   '{HERO,COMPARISON,BENEFITS,SPECIFICATIONS,TRUST,PRICE,FINAL_CTA}',
   '{FAQ,SHIPPING}','{}',
   'HERO_COMPARISON',
   '{HERO,COMPARISON,BENEFITS,SPECIFICATIONS,TRUST,PRICE,FAQ,FINAL_CTA}',
   '{COMPARISON_BASIS,PRODUCT_SPECS}','{no_legitimate_comparison_basis}',
   '{"primary":"add_to_cart"}', 45),
 ('LIFESTYLE_EMOTIONAL','Identity/feeling-led',
   '{apparel,lifestyle,gifting}','{discovery_social}',
   '{HERO,PRODUCT_GALLERY,BENEFITS,OFFER,PRICE,FINAL_CTA}',
   '{SOCIAL_EVIDENCE,RETURNS}','{}',
   'HERO_LIFESTYLE',
   '{HERO,PRODUCT_GALLERY,BENEFITS,OFFER,PRICE,RETURNS,FINAL_CTA}',
   '{PRODUCT_IMAGE}','{purely_functional_no_emotional_angle}',
   '{"primary":"add_to_cart"}', 55),
 ('DIRECT_RESPONSE_OFFER','Offer/urgency-led (legitimate only)',
   '{impulse,bundle}','{cold_direct_response}',
   '{HERO,OFFER,BENEFITS,PRICE,TRUST,STICKY_ADD_TO_CART,FINAL_CTA}',
   '{SHIPPING,FAQ}','{}',
   'HERO_OFFER',
   '{HERO,OFFER,BENEFITS,TRUST,PRICE,SHIPPING,STICKY_ADD_TO_CART,FINAL_CTA}',
   '{GENUINE_OFFER}','{no_legitimate_offer}',
   '{"primary":"add_to_cart","sticky":true}', 60)
ON CONFLICT (family) DO UPDATE SET
  use_case=EXCLUDED.use_case, categories=EXCLUDED.categories, traffic_fit=EXCLUDED.traffic_fit,
  required_sections=EXCLUDED.required_sections, optional_sections=EXCLUDED.optional_sections,
  excluded_sections=EXCLUDED.excluded_sections, hero_variant=EXCLUDED.hero_variant,
  ordering_strategy=EXCLUDED.ordering_strategy, evidence_requirements=EXCLUDED.evidence_requirements,
  disqualifiers=EXCLUDED.disqualifiers, cta_structure=EXCLUDED.cta_structure,
  selection_priority=EXCLUDED.selection_priority, is_active=true;

COMMENT ON TABLE public.conversion_template_families IS
 'Locked 8 conversion template families (P8 contract). Reference data; RLS on; readable by authenticated, writable by service_role.';
