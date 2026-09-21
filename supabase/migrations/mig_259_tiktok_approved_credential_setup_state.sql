-- ============================================================================
-- mig_259_tiktok_approved_credential_setup_state.sql
-- STRATELOQ-TIKTOK-COMMERCIAL-CONTENT-CONNECTION-014A (truthful status update only)
--
-- The founder received official TikTok Commercial Content API approval:
--   client status Connected, approved scope research.adlib.basic, Client Key +
--   Client Secret issued (NOT shared with Claude; never stored in the DB).
--
-- This migration ONLY advances the truthful project-level TikTok state on the
-- provider_capability_registry row from
--   BLOCKED_EXTERNAL_APPROVAL / APPLICATION_SUBMITTED
-- to
--   APPROVED_CREDENTIAL_SETUP_REQUIRED
-- and records the approved scope + the still-missing runtime implementation.
--
-- CRITICAL SAFETY: availability stays 'SOURCE_UNSUPPORTED'. This is deliberate.
--   * The runtime source-state for TikTok therefore REMAINS
--     BLOCKED_EXTERNAL_ACCESS in every research run (no dispatch, no live call).
--   * It is NOT marked AVAILABLE / CONNECTED_RUNTIME / EVIDENCE_FOUND. Those are
--     earned only by a real authenticated Commercial Content API request that
--     succeeds — which cannot happen yet because (a) credentials are not installed
--     and (b) no TikTok executor branch / n8n workflow / SOCIAL_VIDEO ingestion
--     contract exists (fn_research_ingest_source returns UNKNOWN_SOURCE for TIKTOK).
--   * No credential value is stored in the database. Provider API credentials live
--     in the n8n credential store (the established pattern for DataForSEO / eBay /
--     Meta / CJ / Reddit); the DB holds only capability/state metadata.
--
-- No WPS scoring change, no synthetic evidence, no Lovable change, no publish.
-- ============================================================================
UPDATE public.provider_capability_registry
SET
  capability = jsonb_build_object(
    'commercial_content_api', jsonb_build_object(
      'client_status', 'CONNECTED',
      'approved_scope', 'research.adlib.basic',
      'scope_description', 'Access to public commercial data for research purposes',
      'credentials_location', 'n8n_credential_store',
      'credentials_installed', false,
      'runtime_executor_implemented', false,
      'ingestion_contract_implemented', false
    ),
    'project_state', 'APPROVED_CREDENTIAL_SETUP_REQUIRED'
  ),
  limitations = 'APPROVED_CREDENTIAL_SETUP_REQUIRED: TikTok Commercial Content API approved (scope research.adlib.basic, client Connected). Credentials NOT yet installed in the n8n credential store; TikTok executor branch, n8n workflow and SOCIAL_VIDEO ingestion contract NOT yet implemented (fn_research_ingest_source has no TIKTOK branch). Runtime stays BLOCKED_EXTERNAL_ACCESS until a real authenticated research.adlib request succeeds. No credential value stored in the DB.',
  last_verified_at = now(),
  updated_at = now()
WHERE source = 'TIKTOK' AND evidence_category = 'SOCIAL_VIDEO';
