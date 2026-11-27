-- mig_378 — BE325 reversible HISTORICAL rights quarantine (DATA, not schema).
-- Marks the previously-generated assets + generated media outputs whose REFERENCE/SOURCE images were CJ
-- supplier or marketplace photographs WITHOUT verified commercial-reuse/derivative/AI-input rights (per BE239).
-- Quarantine is applied via the reversible provenance flag `rights_quarantine_active=true` (enforced by the
-- mig_377 gates: fn_commercial_generated_asset_use + fn_media_launch_eligibility) plus is_launch_safe=false on
-- media assets. It does NOT change the commercial_asset_status / approval_state enum columns (those carry CHECK
-- constraints), DELETES NOTHING, and records the prior values in provenance for rollback.
-- Idempotent: rows already flagged are skipped so the captured prior state is never overwritten.
-- NOT APPLIED here originally (founder control); applied under BE326 founder deployment approval.
--
-- Scope (verified BE325): 3 selectable IDENTITY_VALIDATED generated assets on product e453eed4 (reference
-- SUPPLIER_PROVIDED; the 4th is already REJECT_GENERATED_ASSET); 5 generated media outputs from supplier/
-- marketplace jobs; 1 launch-safe SUPPLIER_AUTHORIZED media asset. None has verified commercial/AI-input rights.

-- === QUARANTINE (reversible; flag-only, no enum writes) =======================
UPDATE public.commerce_generated_assets
   SET updated_at = now(),
       provenance = coalesce(provenance,'{}'::jsonb) || jsonb_build_object(
         'rights_quarantine_active', true,
         'rights_quarantine', jsonb_build_object(
           'be','BE325','at', now(), 'reversible', true,
           'reason','reference_rights_state is SUPPLIER_PROVIDED without verified commercial/AI-input rights (BE239: CJ images not licensed for reuse)',
           'prior_commercial_asset_status', commercial_asset_status,
           'prior_selected', selected))
 WHERE id IN (
   '6603a98d-84eb-4779-9874-daf303eb4ee9',
   'd2a6e09a-7940-434e-a65a-f33faa9fa29d',
   '03f03347-1d4a-49ba-ab79-4e255e2aba69')
   AND coalesce((provenance->>'rights_quarantine_active'),'false') <> 'true';  -- idempotent

UPDATE public.media_assets
   SET is_launch_safe = false,
       updated_at = now(),
       provenance = coalesce(provenance,'{}'::jsonb) || jsonb_build_object(
         'rights_quarantine_active', true,
         'rights_quarantine', jsonb_build_object(
           'be','BE325','at', now(), 'reversible', true,
           'reason','generated/approved from a supplier or marketplace source image without verified commercial/AI-input rights',
           'prior_approval_state', approval_state,
           'prior_is_launch_safe', is_launch_safe))
 WHERE id IN (
   '8ab3a7f0-20f0-4d66-81cf-ea8d17efcd5e',   -- job b1f7a5f7 (SUPPLIER_PROVIDED)
   '7c6ff093-5960-4149-a9f6-0077ca283d7c',   -- job a9d76292 (MARKETPLACE)
   '469a7aa1-cbbd-4282-ba16-10becd73eb4e',   -- job 339b8195 (MARKETPLACE)
   '6ed3d3dd-d4cd-464e-9931-ccf11e4634e2',   -- job 17d560b4 (MARKETPLACE)
   'f8c569bb-5dc9-4c1e-9b9a-61d5ea90e58c',   -- job 23c62711 (SUPPLIER_PROVIDED)
   'b51602e2-1a57-445a-b55e-9e2792c2988a')   -- launch-safe SUPPLIER_AUTHORIZED image (over-grant)
   AND coalesce((provenance->>'rights_quarantine_active'),'false') <> 'true';  -- idempotent

-- === ROLLBACK (un-quarantine; run only if rights are later verified or to revert) =====================
-- UPDATE public.commerce_generated_assets
--    SET is_launch_safe = is_launch_safe, updated_at = now(),
--        provenance = (provenance - 'rights_quarantine_active' - 'rights_quarantine')
--  WHERE coalesce((provenance->>'rights_quarantine_active'),'false')='true'
--    AND provenance->'rights_quarantine'->>'be'='BE325'
--    AND id IN ('6603a98d-84eb-4779-9874-daf303eb4ee9','d2a6e09a-7940-434e-a65a-f33faa9fa29d','03f03347-1d4a-49ba-ab79-4e255e2aba69');
-- UPDATE public.media_assets
--    SET is_launch_safe = (provenance->'rights_quarantine'->>'prior_is_launch_safe')::boolean,
--        updated_at = now(),
--        provenance = (provenance - 'rights_quarantine_active' - 'rights_quarantine')
--  WHERE coalesce((provenance->>'rights_quarantine_active'),'false')='true'
--    AND provenance->'rights_quarantine'->>'be'='BE325'
--    AND id IN ('8ab3a7f0-20f0-4d66-81cf-ea8d17efcd5e','7c6ff093-5960-4149-a9f6-0077ca283d7c','469a7aa1-cbbd-4282-ba16-10becd73eb4e','6ed3d3dd-d4cd-464e-9931-ccf11e4634e2','f8c569bb-5dc9-4c1e-9b9a-61d5ea90e58c','b51602e2-1a57-445a-b55e-9e2792c2988a');