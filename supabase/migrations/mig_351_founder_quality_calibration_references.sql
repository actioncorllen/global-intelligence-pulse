-- mig_351: Founder-approved quality calibration references (iteration 2 close-out).
--
-- Context: the founder APPROVED the v2 BOLD_SIGNAL and EDITORIAL_INTELLIGENCE candidates and
-- designated them as the founder-approved QUALITY CALIBRATION REFERENCES for their design families.
--
-- CRITICAL SEMANTICS (per founder directive): these are quality / art-direction REFERENCES, NOT
-- fixed templates. Future creatives MUST be free to use different compositions, visual metaphors,
-- layouts, copy, campaign objectives and supporting graphics, while meeting OR exceeding the
-- approved level of art direction, typography, hierarchy, composition, graphic sophistication,
-- message/visual relationship, brand consistency and professional finish.
--
-- This migration is global design-system policy (creative_design_families has no tenant scope):
-- it records the governance envelope + founder observations. The concrete tenant-scoped exemplar
-- pointers (approved concept ids, achieved scores, image refs) are recorded at runtime in
-- creative_learning_records via the existing learning loop (NOT here).
--
-- Additive only: existing reference_calibration keys (reference, principles) are preserved via
-- jsonb merge (||). No schema redesign, no table drop, no policy change.

BEGIN;

-- Shared governance envelope: what may vary vs. what must meet-or-exceed the approved reference.
-- enforced_premium_floor stays at the existing premium gate threshold (85) to AVOID ratcheting
-- the bar above the approved level and thereby blocking legitimate future variation; the achieved
-- scores are recorded as observed evidence (approved_*_observed) rather than as a new hard floor.

UPDATE public.creative_design_families
SET reference_calibration = reference_calibration || jsonb_build_object(
  'founder_calibration', jsonb_build_object(
    'status', 'FOUNDER_APPROVED_REFERENCE',
    'is_template', false,
    'role', 'founder_approved_quality_calibration_reference',
    'quality_bar', 'meet_or_exceed_approved_reference',
    'approved_on', '2026-10-05',
    'enforced_premium_floor', 85,
    'approved_base_observed', 89.74,
    'approved_premium_observed', 85.31,
    'may_vary', jsonb_build_array(
      'composition','visual_metaphor','layout','copy','campaign_objective','supporting_graphics'),
    'must_meet_or_exceed', jsonb_build_array(
      'art_direction','typography','hierarchy','composition','graphic_sophistication',
      'message_visual_relationship','brand_consistency','professional_finish'),
    'founder_observations', jsonb_build_array(
      'Bottom microcopy "SIGNAL DETECTED -> OPPORTUNITY" could have slightly stronger legibility in future generations.'),
    'do_not_regenerate_for_observations', true
  )
)
WHERE family_key = 'BOLD_SIGNAL';

UPDATE public.creative_design_families
SET reference_calibration = reference_calibration || jsonb_build_object(
  'founder_calibration', jsonb_build_object(
    'status', 'FOUNDER_APPROVED_REFERENCE',
    'is_template', false,
    'role', 'founder_approved_quality_calibration_reference',
    'quality_bar', 'meet_or_exceed_approved_reference',
    'approved_on', '2026-10-05',
    'enforced_premium_floor', 85,
    'approved_base_observed', 90.32,
    'approved_premium_observed', 86.69,
    'may_vary', jsonb_build_array(
      'composition','visual_metaphor','layout','copy','campaign_objective','supporting_graphics'),
    'must_meet_or_exceed', jsonb_build_array(
      'art_direction','typography','hierarchy','composition','graphic_sophistication',
      'message_visual_relationship','brand_consistency','professional_finish'),
    'founder_observations', jsonb_build_array(
      'Preserve a slightly cleaner reading zone around body copy when decorative data lines are present.'),
    'do_not_regenerate_for_observations', true
  )
)
WHERE family_key = 'EDITORIAL_INTELLIGENCE';

COMMIT;

-- ----------------------------------------------------------------------------
-- Self-test: proves the calibration references are recorded as references (not
-- templates), that governance is complete, and that existing keys are preserved.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_ci_calibration_reference_selftest()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $fn$
DECLARE
  results jsonb := '[]'::jsonb; passed int := 0; total int := 0;
  fam record;
BEGIN
  -- helper inline: iterate the two calibration families
  FOR fam IN
    SELECT family_key, reference_calibration AS rc
    FROM public.creative_design_families
    WHERE family_key IN ('BOLD_SIGNAL','EDITORIAL_INTELLIGENCE')
  LOOP
    -- founder_calibration present
    total := total + 1;
    IF fam.rc ? 'founder_calibration' THEN passed := passed + 1;
      results := results || jsonb_build_object('case', fam.family_key||'_has_founder_calibration','pass',true);
    ELSE results := results || jsonb_build_object('case', fam.family_key||'_has_founder_calibration','pass',false); END IF;

    -- is a REFERENCE, not a template
    total := total + 1;
    IF (fam.rc->'founder_calibration'->>'is_template') = 'false' THEN passed := passed + 1;
      results := results || jsonb_build_object('case', fam.family_key||'_is_reference_not_template','pass',true);
    ELSE results := results || jsonb_build_object('case', fam.family_key||'_is_reference_not_template','pass',false); END IF;

    -- may_vary >= 6 dimensions (creatives free to differ)
    total := total + 1;
    IF jsonb_array_length(fam.rc->'founder_calibration'->'may_vary') >= 6 THEN passed := passed + 1;
      results := results || jsonb_build_object('case', fam.family_key||'_may_vary_dims','pass',true);
    ELSE results := results || jsonb_build_object('case', fam.family_key||'_may_vary_dims','pass',false); END IF;

    -- must_meet_or_exceed >= 8 quality dimensions
    total := total + 1;
    IF jsonb_array_length(fam.rc->'founder_calibration'->'must_meet_or_exceed') >= 8 THEN passed := passed + 1;
      results := results || jsonb_build_object('case', fam.family_key||'_must_meet_dims','pass',true);
    ELSE results := results || jsonb_build_object('case', fam.family_key||'_must_meet_dims','pass',false); END IF;

    -- existing seed keys preserved (additive merge, not clobber)
    total := total + 1;
    IF (fam.rc ? 'principles') AND (fam.rc ? 'reference') THEN passed := passed + 1;
      results := results || jsonb_build_object('case', fam.family_key||'_seed_keys_preserved','pass',true);
    ELSE results := results || jsonb_build_object('case', fam.family_key||'_seed_keys_preserved','pass',false); END IF;

    -- founder observations recorded, regen suppressed for minor points
    total := total + 1;
    IF jsonb_array_length(fam.rc->'founder_calibration'->'founder_observations') >= 1
       AND (fam.rc->'founder_calibration'->>'do_not_regenerate_for_observations') = 'true' THEN passed := passed + 1;
      results := results || jsonb_build_object('case', fam.family_key||'_founder_observations','pass',true);
    ELSE results := results || jsonb_build_object('case', fam.family_key||'_founder_observations','pass',false); END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'suite','founder_quality_calibration_references',
    'total', total, 'passed', passed, 'failed', total - passed,
    'all_pass', (passed = total),
    'results', results);
END;
$fn$;
