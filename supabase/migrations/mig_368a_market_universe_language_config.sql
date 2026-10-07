-- mig_368a — Authoritative DataForSEO language per supported market
--
-- ROOT CAUSE: production resolved a provider LOCATION per market
-- (ecommerce_market_universe.dataforseo_location_code) but had no authoritative
-- LANGUAGE. The discovery relay therefore carried a hardcoded language (en) that
-- was correct for GB/US but invalid for DE/IT/FR/etc. DataForSEO rejects a
-- location+language mismatch with 40501 "Invalid Field: language_code" (DE
-- location 2276 requires de, not en). Every non-English market was a latent
-- 40501, and the only "fix" was a human remembering to change the language by
-- hand — exactly the "remembering config" anti-pattern.
--
-- PERMANENT FIX (smallest production change at the authoritative boundary):
-- carry the valid DataForSEO language_code for each market alongside its
-- location_code in the one authoritative supported-market config table. The
-- resolver (mig_368b) and the discovery relay then derive language from here;
-- nothing downstream hardcodes it. DataForSEO language codes are ISO-639-1
-- (country-appropriate) and are paired with the existing location codes.
--
-- Idempotent: ADD COLUMN IF NOT EXISTS + authoritative VALUES-mapped UPDATE.

ALTER TABLE public.ecommerce_market_universe
  ADD COLUMN IF NOT EXISTS dataforseo_language_code text;

-- Authoritative market -> DataForSEO language_code mapping. Only markets that
-- have a provider location are given a language; non-eligible markets stay NULL
-- and are filtered out by the resolver's NO_PROVIDER_LANGUAGE / eligibility gate.
UPDATE public.ecommerce_market_universe u
   SET dataforseo_language_code = m.lang
  FROM (VALUES
    ('AT','de'),('AU','en'),('BE','nl'),('CA','en'),('CH','de'),
    ('DE','de'),('DK','da'),('ES','es'),('FR','fr'),('GB','en'),
    ('HK','en'),('IE','en'),('IT','it'),('MY','en'),('NL','nl'),
    ('NO','no'),('PH','en'),('PL','pl'),('SE','sv'),('SG','en'),
    ('US','en')
  ) AS m(country_code, lang)
 WHERE upper(u.country_code) = m.country_code
   AND u.dataforseo_language_code IS DISTINCT FROM m.lang;
