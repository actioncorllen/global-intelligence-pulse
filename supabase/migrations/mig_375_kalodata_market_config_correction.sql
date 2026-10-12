-- mig_375 — Kalodata market config correction: IE is not a Kalodata region
--
-- Permanent-fix rule: provider market support must come from authoritative provider
-- capability evidence, not Strateloq's own country list. Kalodata Product Ranking supported
-- regions (founder-observed provider capability docs): US / BR / MX / ID / JP / MY / PH / SG
-- / TH / VN / GB / ES / DE / FR / IT. IE is NOT among them, but mig_374a had inserted IE as
-- supported. This corrects the config so the COMMERCE lane returns UNSUPPORTED_MARKET for IE
-- and never substitutes GB/DE or any other market.
--
-- The 9 markets left enabled (DE, ES, FR, GB, IT, MY, PH, SG, US) are all within the
-- authoritative Kalodata region list. No market is added without evidence; the remaining
-- authoritative regions (BR/MX/ID/JP/TH/VN) are left unconfigured and can be enabled later
-- through the same data-driven mechanism when needed.
--
-- Required DE regression: fn_kalodata_commerce_adapter_selftest check 17
-- (17_IE_NOT_SILENTLY_SUPPORTED) proves IE cannot silently become supported without provider
-- capability configuration (see mig_374d).

UPDATE public.discovery_provider_market_config
SET supported = false,
    enabled   = false,
    note      = 'IE is NOT an established Kalodata region per provider Product Ranking capability evidence (supported: US/BR/MX/ID/JP/MY/PH/SG/TH/VN/GB/ES/DE/FR/IT). Disabled pending provider evidence; COMMERCE returns UNSUPPORTED_MARKET for IE, never substituted.',
    updated_at = now()
WHERE provider = 'KALODATA' AND market = 'IE';
