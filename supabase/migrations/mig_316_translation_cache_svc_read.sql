-- mig_316_translation_cache_svc_read.sql
--
-- Stage 3 translate-text support: a service_role-only cache READER that mirrors
-- fn_text_translations (mig_313) WITHOUT the auth.uid() gate.
--
-- Why: the translate-text Edge Function has ALREADY authenticated the signed-in user (verify_jwt
-- + /auth/v1/user) and then calls the shared translation cache with the SERVICE ROLE key, under
-- which auth.uid() is NULL. The uid-gated fn_text_translations would therefore fail closed and
-- return no hits, defeating the cache and forcing a paid Gemini call for text already translated.
-- This reader is the read counterpart to fn_text_translations_put (mig_315): service_role only,
-- never exposed to anon/authenticated, operating on the SHARED, non-tenant dictionary (keyed by
-- md5(source)+target_lang; it holds no tenant/pricing/identity data, so it cannot leak tenant info).
-- The browser keeps using the uid-gated fn_text_translations; only the server uses this one.

CREATE OR REPLACE FUNCTION public.fn_text_translations_read_svc(p_target_lang text, p_texts text[])
 RETURNS jsonb
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_lang text := lower(btrim(coalesce(p_target_lang,'')));
  v jsonb;
BEGIN
  IF v_lang = '' THEN RETURN jsonb_build_object('status','language_required'); END IF;
  SELECT coalesce(jsonb_object_agg(z.src, z.obj), '{}'::jsonb) INTO v
  FROM (
    SELECT q.src,
           jsonb_strip_nulls(jsonb_build_object(
             'translated', c.translated_text,
             'source_lang', c.source_lang,
             'provenance', c.provenance)) AS obj
    FROM (
      SELECT DISTINCT btrim(x) AS src
      FROM unnest(coalesce(p_texts, '{}'::text[])) x
      WHERE btrim(coalesce(x,'')) <> ''
    ) q
    LEFT JOIN public.text_translation_cache c
      ON c.source_key = md5(q.src) AND c.target_lang = v_lang
  ) z;
  RETURN jsonb_build_object('status','ok','target_lang',v_lang,'translations',v,
    'authority','INTERNAL_TRANSLATION','contract','pulse_text_translations_read_svc_v1');
END; $function$;

REVOKE ALL ON FUNCTION public.fn_text_translations_read_svc(text, text[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_text_translations_read_svc(text, text[]) TO service_role;
COMMENT ON FUNCTION public.fn_text_translations_read_svc(text, text[]) IS
  'pulse_text_translations_read_svc_v1 — service_role-only cache reader (no auth.uid() gate) for the translate-text edge function, which authenticates the user itself. Shared non-tenant dictionary; originals never mutated. Browser uses fn_text_translations instead.';
