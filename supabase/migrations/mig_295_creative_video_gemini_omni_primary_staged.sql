-- STRATELOQ — COMMERCIAL CREATIVE PRODUCTION UPGRADE
-- Register gemini-omni-1.1-flash as the intended PRIMARY generative-video provider,
-- STAGED / DISABLED, mirroring how GEMINI_VEO_VIDEO (the veo-3.1-fast fallback) was
-- staged in mig_287. This is additive server-side model configuration only.
--
-- WHY DISABLED: gemini-omni-1.1-flash is a PAID model (Gemini Developer API
-- Interactions API; ~USD 0.03/s at 360p up to ~USD 0.30/s at 4K). No billable
-- generation is authorized. fn_media_provider_for() selects only ENABLED providers
-- (WHERE enabled ...), so an enabled=false row has ZERO effect on the running
-- system and cannot dispatch a paid call. Enabling it (and honouring a
-- PRIMARY gemini-omni -> FALLBACK veo-3.1-fast selection order) is gated on a
-- founder-authorized bounded paid run — see runtime_status below.
--
-- Product identity: IMAGE_TO_VIDEO seeds the authoritative Product Card frame but
-- subsequent frames are model-generated, so the route stays IDENTITY_REVIEW_REQUIRED
-- (SEED_ONLY). Provider success is NOT sufficient for launch-safety
-- (STRATELOQ-CREATIVE-STUDIO-QUALITY-STANDARD.md §2/§3/§23). No secret is stored in
-- this row; the Google credential lives server-side only (n8n credential / edge env).
--
-- Additive + reversible: DELETE FROM public.media_providers WHERE name='GEMINI_OMNI_VIDEO'; to revert.
-- RLS on media_providers is unchanged. No other row is modified.

INSERT INTO public.media_providers (name, media_type, enabled, config)
SELECT
  'GEMINI_OMNI_VIDEO',
  'VIDEO',
  false,
  jsonb_build_object(
    'role', 'GENERATIVE_VIDEO',
    'selection_role', 'PRIMARY',
    'fallback_provider', 'GEMINI_VEO_VIDEO',
    'capability', jsonb_build_object(
      'model', 'gemini-omni-1.1-flash',
      'api', 'Gemini Developer API (Interactions API)',
      'modes', jsonb_build_array('IMAGE_TO_VIDEO','TEXT_TO_VIDEO','CONVERSATIONAL_EDIT'),
      'resolutions', jsonb_build_array('360p','720p','1080p','4k'),
      'aspect_ratios', jsonb_build_array('9:16','16:9','1:1'),
      'duration_s_per_clip', jsonb_build_array(3,10),
      'scene_extension_cumulative_s', 40,
      'native_audio', true,
      'image_to_video_supported', true,
      'video_references_supported', true,
      'first_last_frame_control', true,
      'generation_method', 'interactions',
      'preserves_authoritative_product_input',
        'SEED_ONLY: the authoritative Product Card frame anchors the reference/first frame; subsequent frames are model-generated and may drift, so product identity is NOT guaranteed across motion and stays IDENTITY_REVIEW_REQUIRED'
    ),
    'credential', jsonb_build_object(
      'type', 'googlePalmApi',
      'ownership', 'OWN_EXISTING_CREDENTIAL (no new external account required)',
      'note', 'gemini-omni-1.1-flash is reached via the Gemini Developer API Interactions API with the existing own Google Gemini key'
    ),
    'cost', jsonb_build_object(
      'billing', 'usage-based per second (Google Gemini API / Gemini Omni)',
      'est_basis', 'INDICATIVE ONLY, not a quote: Google-listed effective output ~USD 0.03/s at 360p, ~0.10/s at 720p, ~0.15/s at 1080p, ~0.30/s at 4K',
      'one_bounded_clip_est_usd', 'approx 0.24 to 1.20 for a single 8s clip at 360p-1080p (tier-dependent); confirm live',
      'proposed_max_authorized_usd', 2
    ),
    'identity', 'IMAGE_TO_VIDEO seeds the real Product Card frame but generates motion frames -> route stays IDENTITY_REVIEW_REQUIRED; provider success is NOT sufficient (STRATELOQ-CREATIVE-STUDIO-QUALITY-STANDARD.md §2/§3/§23)',
    'entitlement', jsonb_build_object(
      'state', 'MODEL_GA_2026_08_27',
      'model_availability', 'gemini-omni-1.1-flash is generally available (2026-08-27) on the Gemini Developer API; the deprecated preview gemini-omni-flash-preview is retired 2026-09-30 and MUST NOT be used',
      'verified_free', false,
      'dispatch_verified', false,
      'dispatch_note', 'A real generate call is PAID and has NOT been made; entitlement-to-generate on the own Gemini key must be confirmed by a founder-authorized bounded run'
    ),
    'runtime_status', 'STAGED_PENDING_FOUNDER_COST_APPROVAL — intended PRIMARY generative-video engine (fallback: GEMINI_VEO_VIDEO / veo-3.1-fast-generate-preview). DISABLED so it cannot be selected or dispatch a paid call. Enabling requires: (1) billing enabled on the Google Gemini credential, (2) confirmed key access to the gemini-omni-1.1-flash Interactions API, (3) a founder-authorized max spend, (4) a priority-aware provider selection + an n8n generation workflow. No paid generation authorized by this migration.',
    'secret_storage', 'server_side_only: secret lives in the n8n credential / edge-function env, never in this row'
  )
WHERE NOT EXISTS (
  SELECT 1 FROM public.media_providers WHERE name = 'GEMINI_OMNI_VIDEO'
);
