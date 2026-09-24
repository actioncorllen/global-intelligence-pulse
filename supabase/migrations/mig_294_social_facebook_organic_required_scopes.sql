-- STRATELOQ-016C.9 — align META_FACEBOOK ORGANIC required scopes with reality
-- ----------------------------------------------------------------------------
-- Context: the founder completed the real Meta Login for Business flow and was
-- granted pages_show_list, pages_read_engagement, pages_manage_posts (+ public_
-- profile) — exactly what this app's Login configuration requests. The DB
-- finalize gate (fn_social_meta_finalize -> fn_social_required_scopes) additionally
-- demanded `business_management`, which:
--   * is NOT requested/granted by this app's Facebook Login for Business config,
--   * is NOT needed to mint a Page access token or publish Page posts organically
--     (a valid Page token was obtained for the founder's Page without it), and
--   * therefore made EVERY organic Facebook connection fail the scope gate.
--
-- This migration removes `business_management` from the ORGANIC/META_FACEBOOK
-- required set only. META_INSTAGRAM and every other branch are left byte-for-byte
-- unchanged. `business_management` remains a recognised OPTIONAL scope in the edge
-- layer (recorded when granted); nothing about tenant isolation, FORCE RLS, the
-- organic-only boundary, or advertising is touched.
--
-- Reversible: restore the previous CASE arm (add "business_management" back to the
-- META_FACEBOOK/ORGANIC array) to revert.

CREATE OR REPLACE FUNCTION public.fn_social_required_scopes(
  p_platform text,
  p_connection_type text DEFAULT 'ORGANIC'::text
)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
SET search_path TO ''
AS $function$
  SELECT CASE
    WHEN p_connection_type = 'ORGANIC' AND p_platform = 'META_FACEBOOK'
      THEN '["pages_show_list","pages_read_engagement","pages_manage_posts"]'::jsonb
    WHEN p_connection_type = 'ORGANIC' AND p_platform = 'META_INSTAGRAM'
      THEN '["instagram_basic","instagram_content_publish","pages_show_list","business_management"]'::jsonb
    ELSE '[]'::jsonb
  END;
$function$;
