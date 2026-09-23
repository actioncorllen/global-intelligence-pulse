-- ============================================================================
-- mig_287_video_path_reassessment_gemini_veo.sql
-- STRATELOQ-015Q — Short-form video production path reassessment.
-- Records the VERIFIED (free, metadata-only) finding that the EXISTING own
-- Google Gemini credential (googlePalmApi) can see Veo 3.1 video-generation
-- models — i.e. an image-to-video route exists on an already-configured
-- credential with NO new external account. It remains a PAID route, so it is
-- staged DISABLED and dispatch is gated on explicit founder cost approval.
-- No secret is stored. Nothing here dispatches or spends. Idempotent.
-- Preserves the static system (015L/015M/015O/015P/015P.1) and all identity
-- and claim gates unchanged.
-- ============================================================================

-- Provider registry row for the reassessed, no-new-account video route.
INSERT INTO public.media_providers (name, media_type, enabled, config)
SELECT 'GEMINI_VEO_VIDEO', 'VIDEO', false, '{}'::jsonb
WHERE NOT EXISTS (SELECT 1 FROM public.media_providers WHERE name = 'GEMINI_VEO_VIDEO');

UPDATE public.media_providers
SET media_type = 'VIDEO',
    enabled = false,   -- staged; NOT dispatchable until founder cost approval
    config = jsonb_build_object(
      'role', 'GENERATIVE_VIDEO',
      'capability', jsonb_build_object(
        'modes', jsonb_build_array('IMAGE_TO_VIDEO','TEXT_TO_VIDEO'),
        'models', jsonb_build_array('veo-3.1-generate-preview','veo-3.1-fast-generate-preview','veo-3.1-lite-generate-preview'),
        'generation_method', 'predictLongRunning',
        'aspect_ratios', jsonb_build_array('9:16','16:9','1:1'),
        'duration_s_typical', 8,
        'resolutions', jsonb_build_array('720p','1080p'),
        'image_to_video_supported', true,
        'preserves_authoritative_product_input',
          'SEED_ONLY: the authoritative Product Card frame anchors the FIRST frame; subsequent frames are model-generated and may drift, so product identity is NOT guaranteed across motion'
      ),
      'credential', jsonb_build_object(
        'type', 'googlePalmApi',
        'ownership', 'OWN_EXISTING_CREDENTIAL (no new external account required)',
        'gateway', false,
        'note', 'Gateway googleGemini node exposes only text+image; Veo is reached via the Gemini REST API with the existing own key'
      ),
      'entitlement', jsonb_build_object(
        'state', 'OWN_CREDENTIAL_LISTS_VEO_MODELS',
        'verified_free', true,
        'verification', 'n8n workflow y6pvszAOXJcu147U execution 30261 (2026-09-23): free models.list returned veo-3.1-generate/fast/lite-preview; metadata only, no billable inference',
        'dispatch_verified', false,
        'dispatch_note', 'A real generate call is PAID and has NOT been made; entitlement-to-generate is confirmed only by a founder-authorized bounded run'
      ),
      'cost', jsonb_build_object(
        'billing', 'usage-based per second (Google Gemini API / Veo)',
        'est_basis', 'INDICATIVE ONLY, not a quote: Veo 3.1 fast/lite tiers are the cheapest; order-of-magnitude ~USD 0.10-0.40 per second depending on tier/resolution/audio',
        'one_bounded_clip_est_usd', 'approx 0.8 to 3.2 for a single ~8s 9:16 clip (tier-dependent); confirm live',
        'proposed_max_authorized_usd', 2.00
      ),
      'identity', 'IMAGE_TO_VIDEO seeds the real Product Card frame but generates motion frames -> route stays IDENTITY_REVIEW_REQUIRED; provider success is NOT sufficient (per 015Q section 5)',
      'runtime_status', 'READY_PENDING_FOUNDER_COST_APPROVAL (2026-09-23) — an executable image-to-video route exists on the existing Gemini credential with no new account; it is PAID, so dispatch is blocked until the founder authorizes one bounded run with a max cost. No secret stored here; the key lives server-side in the n8n credential / edge env only.',
      'secret_storage', 'server_side_only: secret lives in the n8n credential / edge-function env, never in this row'
    )
WHERE name = 'GEMINI_VEO_VIDEO';
