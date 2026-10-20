-- mig_313_text_translation_cache.sql
--
-- 18-MARKET & MULTILINGUAL stage (additive, no DROP, NO paid translation services, NO provider calls).
-- Internal, cached translation for free-text product content (titles/descriptions/categories).
-- Reuses the existing market registry for the 18-market selector (fn_ecommerce_supported_markets,
-- already granted to authenticated) — NOT rebuilt here. This migration adds ONLY the internal
-- translation cache + lookup, so the frontend can show a genuine translation when one exists and the
-- ORIGINAL source text otherwise. Translations are produced internally (seeded), never by an external
-- paid service; originals are always preserved. UI labels / controlled vocab / intelligence-summary
-- templates are translated in the frontend i18n layer (no backend needed for those).
--
-- Invariants: server-owned auth (auth.uid()); the cache is a shared dictionary keyed by the exact
-- source text (md5) + target language — it holds NO tenant, pricing, identity or numeric data, so it
-- cannot leak tenant information; a missing translation returns null (the client shows the original).

CREATE TABLE IF NOT EXISTS public.text_translation_cache (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_key    text NOT NULL,                 -- md5(btrim(source_text))
  source_text   text NOT NULL,
  source_lang   text,
  target_lang   text NOT NULL,
  translated_text text NOT NULL,
  provenance    text NOT NULL DEFAULT 'internal_seed',
  created_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (source_key, target_lang)
);
-- The table is exposed ONLY through the SECURITY DEFINER function below; deny all direct table access.
ALTER TABLE public.text_translation_cache ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.text_translation_cache FROM PUBLIC, anon, authenticated;

-- Lookup: given a target language and a set of source strings, return a {source -> {translated,...}}
-- map. A string with no cached translation returns translated=null, so the client keeps the original.
CREATE OR REPLACE FUNCTION public.fn_text_translations(p_target_lang text, p_texts text[])
 RETURNS jsonb
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_lang text := lower(btrim(coalesce(p_target_lang,'')));
  v jsonb;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
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
    'authority','INTERNAL_TRANSLATION','contract','pulse_text_translations_v1');
END; $function$;

REVOKE ALL ON FUNCTION public.fn_text_translations(text, text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_text_translations(text, text[]) TO authenticated, service_role;
COMMENT ON FUNCTION public.fn_text_translations(text, text[]) IS
  'pulse_text_translations_v1 — internal (non-paid) cached translation lookup. Returns a {source->{translated,source_lang}} map; a missing entry returns no translated value so the client keeps the original. No tenant/pricing/identity data; originals never mutated.';

-- Seed: genuine internal German->English translations for the real DE-market product titles that are in
-- German (brand names, model numbers, trademark marks and numeric values preserved verbatim). Titles
-- that are already English are intentionally NOT seeded (the client shows them as-is).
INSERT INTO public.text_translation_cache (source_key, source_text, source_lang, target_lang, translated_text, provenance)
VALUES
 (md5('Gutes Dutzend 12er-Geschenkset je 60g'),
  'Gutes Dutzend 12er-Geschenkset je 60g','de','en',
  'Gutes Dutzend 12-piece gift set, 60 g each','internal_seed_v1'),
 (md5('Halara Flex™ plissierte dehnbare Stoffhose mit hohem Bund, Seitentaschen und geradem Bein'),
  'Halara Flex™ plissierte dehnbare Stoffhose mit hohem Bund, Seitentaschen und geradem Bein','de','en',
  'Halara Flex™ pleated stretch fabric trousers with high waist, side pockets and straight leg','internal_seed_v1'),
 (md5('JONR ED12 Nass und Trockenstaubsauger Selbstreinigend Kabellos Bodenreiniger Leichter Mopp für Hartböden Tierhaare Essensreste Rundum Reinigung ohne Auslass'),
  'JONR ED12 Nass und Trockenstaubsauger Selbstreinigend Kabellos Bodenreiniger Leichter Mopp für Hartböden Tierhaare Essensreste Rundum Reinigung ohne Auslass','de','en',
  'JONR ED12 wet and dry vacuum cleaner, self-cleaning, cordless floor cleaner, lightweight mop for hard floors, pet hair and food residue, all-around cleaning with no exhaust outlet','internal_seed_v1'),
 (md5('Karaca Earth Collection Cupid 55-teiliges 12-Personen-Geschirrset'),
  'Karaca Earth Collection Cupid 55-teiliges 12-Personen-Geschirrset','de','en',
  'Karaca Earth Collection Cupid 55-piece 12-person dinnerware set','internal_seed_v1'),
 (md5('Ninja DualZone XL-Heißluftfritteuse mit 9,5 l Fassungsvermögen und 2 Schubladen – Grau'),
  'Ninja DualZone XL-Heißluftfritteuse mit 9,5 l Fassungsvermögen und 2 Schubladen – Grau','de','en',
  'Ninja DualZone XL air fryer with 9.5 L capacity and 2 drawers – Grey','internal_seed_v1')
ON CONFLICT (source_key, target_lang) DO NOTHING;

-- Selftest (service_role only): auth gate, language gate, a seeded DE->EN hit, and an unseeded miss
-- (original preserved).
CREATE OR REPLACE FUNCTION public.fn_text_translations_selftest()
 RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_checks jsonb := '[]'::jsonb; v_pass int := 0; v_fail int := 0;
  v_prev text; v_r jsonb;
BEGIN
  v_prev := current_setting('request.jwt.claims', true);

  -- language gate (authenticated)
  PERFORM set_config('request.jwt.claims', json_build_object('sub','7c8ddf9d-172c-4a89-a402-bb7066228b61')::text, true);
  v_r := public.fn_text_translations('', ARRAY['x']);
  v_checks := v_checks || jsonb_build_object('check','LANGUAGE_REQUIRED','ok', v_r->>'status'='language_required','detail',v_r);

  -- seeded German title -> English
  v_r := public.fn_text_translations('en', ARRAY['Ninja DualZone XL-Heißluftfritteuse mit 9,5 l Fassungsvermögen und 2 Schubladen – Grau']);
  v_checks := v_checks || jsonb_build_object('check','DE_TO_EN_HIT',
    'ok', v_r->'translations'->'Ninja DualZone XL-Heißluftfritteuse mit 9,5 l Fassungsvermögen und 2 Schubladen – Grau'->>'translated'
          = 'Ninja DualZone XL air fryer with 9.5 L capacity and 2 drawers – Grey',
    'detail', v_r->'translations');

  -- unseeded / already-English title -> no translated value (original preserved)
  v_r := public.fn_text_translations('en', ARRAY['Balance Shake']);
  v_checks := v_checks || jsonb_build_object('check','MISS_KEEPS_ORIGINAL',
    'ok', (v_r->'translations'->'Balance Shake'->>'translated') IS NULL,
    'detail', v_r->'translations');

  -- unauthenticated fails closed
  PERFORM set_config('request.jwt.claims', '', true);
  v_r := public.fn_text_translations('en', ARRAY['Balance Shake']);
  v_checks := v_checks || jsonb_build_object('check','UNAUTH_FAILS_CLOSED','ok', v_r->>'status'='unauthenticated','detail',v_r);

  PERFORM set_config('request.jwt.claims', coalesce(v_prev,''), true);

  SELECT count(*) FILTER (WHERE (c->>'ok')::boolean), count(*) FILTER (WHERE NOT (c->>'ok')::boolean)
    INTO v_pass, v_fail FROM jsonb_array_elements(v_checks) c;
  RETURN jsonb_build_object('ok', v_fail=0, 'passed',v_pass,'failed',v_fail,'total',v_pass+v_fail,
    'checks',v_checks,'contract','pulse_text_translations_selftest_v1','generated_at',now());
END; $function$;

REVOKE ALL ON FUNCTION public.fn_text_translations_selftest() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_text_translations_selftest() TO service_role;
