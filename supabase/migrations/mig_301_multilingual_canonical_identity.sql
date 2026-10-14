-- mig_301_multilingual_canonical_identity.sql
-- STRATELOQ — multilingual Product Identity -> CJ supplier query (extends the B3 fix, mig_300).
--
-- Problem: non-English product terminology (German "Krippen", French "crèche", Spanish "belén", etc.)
-- is only converted to a language-independent canonical identity when its exact surface is in
-- fn_canonical_concepts' lexicon, and that lexicon was (a) accent-SENSITIVE (so accented French/Italian/
-- Spanish/Portuguese/Polish spellings missed) and (b) narrow. When canonicalisation produced nothing, the
-- supplier query fell back to the source-language phrase and failed against CJ's English productNameEn.
--
-- Fix (generic, deterministic, reuses existing architecture; NO new paid service; NO translation API):
--  1) fn_fold_accents(text): deterministic diacritic folding (DE/FR/IT/ES/PT/PL/NL + Nordic) via translate()
--     + replace() for the ß/æ/œ digraphs. IMMUTABLE, no extension required.
--  2) fn_canonical_concepts: folds the input before lexicon matching, and broadens the multilingual
--     recognition surfaces across the 18 markets' languages for the existing concepts, PLUS adds a second
--     product family (HUMIDIFIER) to demonstrate the mechanism is generic, not nativity-specific. Output
--     contract (concepts / distinguishing / surfaces) is UNCHANGED, so fn_market_supplier_match,
--     fn_derive_concrete_product_identity and fn_supplier_search_terms consume it unchanged. English-title
--     behaviour is unchanged (folding is a no-op on ASCII). The English query-GENERATION surfaces live in
--     fn_supplier_search_terms (mig_300); concepts without an explicit generation surface are humanised
--     there, so a newly-recognised concept flows end-to-end without a second lexicon edit.
--  3) fn_stage2_supplier_search_queries: adds language_coverage_gap observability — when a non-English
--     market yields SOURCE_PHRASE_FALLBACK (no canonical concept), the response flags that the supplier
--     query is a low-confidence source-language fallback (so the orchestrator does not treat a German/French
--     query as a confident English search). Fail-safe + honest; does not fabricate a translation.
--
-- Preserved: original product names, source evidence, exact matching strictness, form-conflict detection,
-- per-country (18-market) independent intelligence and isolation, tenant isolation, Product Asset Lock.
-- Out of scope (unchanged): CJ pagination (pageNum/pageSize); no live CJ/Apify calls.

-- ---------------------------------------------------------------------------------------------------
-- (1) Deterministic accent folding (IMMUTABLE; no extension).
-- ---------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_fold_accents(p text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path TO ''
AS $function$
  SELECT translate(
    replace(replace(replace(lower(coalesce(p,'')), 'ß','ss'), 'æ','ae'), 'œ','oe'),
    'áàâäãåāąéèêëēęíìîïīóòôöõōøúùûüūçćčñńšśžźżłýÿ',
    'aaaaaaaaeeeeeeiiiiiooooooouuuuucccnnsszzzlyy');
$function$;

REVOKE ALL ON FUNCTION public.fn_fold_accents(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_fold_accents(text) TO service_role, authenticated;

-- ---------------------------------------------------------------------------------------------------
-- (2) Multilingual canonical concepts: accent-folded input + broadened 18-market lexicon.
-- ---------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_canonical_concepts(p_text text)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
SET search_path TO ''
AS $function$
  WITH lex(concept, surface, generic) AS (VALUES
    -- NATIVITY_SCENE (distinguishing noun) — DE/EN/FR/ES/IT/PL/NL
    ('NATIVITY_SCENE','krippe',false),('NATIVITY_SCENE','krippen',false),('NATIVITY_SCENE','weihnachtskrippe',false),
    ('NATIVITY_SCENE','krippenlandschaft',false),
    ('NATIVITY_SCENE','nativity',false),('NATIVITY_SCENE','nativity scene',false),('NATIVITY_SCENE','nativity set',false),
    ('NATIVITY_SCENE','manger scene',false),('NATIVITY_SCENE','creche',false),('NATIVITY_SCENE','creche de noel',false),
    ('NATIVITY_SCENE','nacimiento',false),('NATIVITY_SCENE','belen',false),('NATIVITY_SCENE','portal de belen',false),
    ('NATIVITY_SCENE','presepe',false),('NATIVITY_SCENE','presepio',false),
    ('NATIVITY_SCENE','szopka',false),('NATIVITY_SCENE','kerststal',false),
    -- ILLUMINATED (distinguishing attribute) — DE/EN/FR/ES/IT/PT/PL/NL
    ('ILLUMINATED','beleuchtet',false),('ILLUMINATED','beleuchtete',false),('ILLUMINATED','beleuchteter',false),
    ('ILLUMINATED','beleuchtetes',false),('ILLUMINATED','beleuchtung',false),('ILLUMINATED','leuchtend',false),
    ('ILLUMINATED','led',false),('ILLUMINATED','illuminated',false),('ILLUMINATED','lighted',false),
    ('ILLUMINATED','light up',false),('ILLUMINATED','light-up',false),('ILLUMINATED','pre-lit',false),('ILLUMINATED','prelit',false),
    ('ILLUMINATED','lumineux',false),('ILLUMINATED','lumineuse',false),('ILLUMINATED','illumine',false),('ILLUMINATED','eclaire',false),
    ('ILLUMINATED','iluminado',false),('ILLUMINATED','iluminada',false),('ILLUMINATED','iluminacion',false),
    ('ILLUMINATED','con luz',false),('ILLUMINATED','con luces',false),
    ('ILLUMINATED','illuminato',false),('ILLUMINATED','luminoso',false),('ILLUMINATED','con luci',false),
    ('ILLUMINATED','com luz',false),('ILLUMINATED','podswietlany',false),('ILLUMINATED','podswietlana',false),('ILLUMINATED','verlicht',false),
    -- FORM:WALL_DECORATION — DE/EN/FR/ES/IT/PT/PL/NL
    ('FORM:WALL_DECORATION','wanddeko',false),('FORM:WALL_DECORATION','wanddekoration',false),
    ('FORM:WALL_DECORATION','wandbehang',false),('FORM:WALL_DECORATION','wandbild',false),('FORM:WALL_DECORATION','wandschmuck',false),
    ('FORM:WALL_DECORATION','wall decoration',false),('FORM:WALL_DECORATION','wall decor',false),
    ('FORM:WALL_DECORATION','wall hanging',false),('FORM:WALL_DECORATION','wall art',false),
    ('FORM:WALL_DECORATION','decoration murale',false),('FORM:WALL_DECORATION','deco murale',false),
    ('FORM:WALL_DECORATION','tenture murale',false),('FORM:WALL_DECORATION','art mural',false),
    ('FORM:WALL_DECORATION','decoracion de pared',false),('FORM:WALL_DECORATION','decoracion mural',false),('FORM:WALL_DECORATION','cuadro de pared',false),
    ('FORM:WALL_DECORATION','decorazione da parete',false),('FORM:WALL_DECORATION','decoro murale',false),('FORM:WALL_DECORATION','quadro da parete',false),
    ('FORM:WALL_DECORATION','decoracao de parede',false),('FORM:WALL_DECORATION','dekoracja scienna',false),
    ('FORM:WALL_DECORATION','wanddecoratie',false),('FORM:WALL_DECORATION','muurdecoratie',false),
    -- FORM:PROJECTOR (contradictory display form)
    ('FORM:PROJECTOR','projektor',false),('FORM:PROJECTOR','projector',false),('FORM:PROJECTOR','projektion',false),
    ('FORM:PROJECTOR','projection',false),('FORM:PROJECTOR','proyector',false),('FORM:PROJECTOR','proiettore',false),
    ('FORM:PROJECTOR','projecteur',false),('FORM:PROJECTOR','projetor',false),
    -- FORM:WALL_LIGHT (contradictory lighting-fixture form)
    ('FORM:WALL_LIGHT','wall light',false),('FORM:WALL_LIGHT','wall lamp',false),('FORM:WALL_LIGHT','wandleuchte',false),
    ('FORM:WALL_LIGHT','wandlampe',false),('FORM:WALL_LIGHT','sconce',false),('FORM:WALL_LIGHT','applique murale',false),
    ('FORM:WALL_LIGHT','lampada da parete',false),('FORM:WALL_LIGHT','lampara de pared',false),
    ('FORM:WALL_LIGHT','kinkiet',false),('FORM:WALL_LIGHT','wandlamp',false),
    -- FORM:FIGURINE_SET (contradictory figurine form)
    ('FORM:FIGURINE_SET','figurine',false),('FORM:FIGURINE_SET','figuren',false),('FORM:FIGURINE_SET','krippenfigur',false),
    ('FORM:FIGURINE_SET','krippenfiguren',false),('FORM:FIGURINE_SET','holzfigur',false),('FORM:FIGURINE_SET','statue',false),
    ('FORM:FIGURINE_SET','figura',false),('FORM:FIGURINE_SET','statuina',false),('FORM:FIGURINE_SET','figurita',false),('FORM:FIGURINE_SET','figurka',false),
    -- FORM:TABLETOP / FORM:STRING_LIGHTS (other contradictory forms)
    ('FORM:TABLETOP','tabletop',false),('FORM:TABLETOP','table top',false),('FORM:TABLETOP','tischdeko',false),
    ('FORM:STRING_LIGHTS','string lights',false),('FORM:STRING_LIGHTS','lichterkette',false),('FORM:STRING_LIGHTS','fairy lights',false),
    ('FORM:STRING_LIGHTS','guirlande lumineuse',false),('FORM:STRING_LIGHTS','tira de luces',false),
    -- HUMIDIFIER (distinguishing noun; generality proof across a different category) — DE/EN/FR/ES/IT/PL/NL
    ('HUMIDIFIER','humidifier',false),('HUMIDIFIER','air humidifier',false),('HUMIDIFIER','mist humidifier',false),
    ('HUMIDIFIER','luftbefeuchter',false),('HUMIDIFIER','humidificateur',false),('HUMIDIFIER','humidificador',false),
    ('HUMIDIFIER','umidificatore',false),('HUMIDIFIER','nawilzacz',false),('HUMIDIFIER','luchtbevochtiger',false),
    -- CHRISTMAS (generic season marker; NOT distinguishing)
    ('CHRISTMAS','weihnacht',true),('CHRISTMAS','weihnachten',true),('CHRISTMAS','weihnachts',true),
    ('CHRISTMAS','christmas',true),('CHRISTMAS','xmas',true),('CHRISTMAS','noel',true),('CHRISTMAS','navidad',true),
    ('CHRISTMAS','natale',true),('CHRISTMAS','natal',true),('CHRISTMAS','kerst',true),('CHRISTMAS','holiday',true)
  ),
  m AS (
    SELECT DISTINCT concept, surface, generic FROM lex
    WHERE public.fn_fold_accents(p_text) ~ ('\y'||replace(surface,' ','\s+')||'\y')
  )
  SELECT jsonb_build_object(
    'concepts',       coalesce((SELECT jsonb_agg(DISTINCT concept) FROM m), '[]'::jsonb),
    'distinguishing', coalesce((SELECT jsonb_agg(DISTINCT concept) FROM m WHERE NOT generic), '[]'::jsonb),
    'surfaces',       coalesce((SELECT jsonb_agg(DISTINCT surface) FROM m), '[]'::jsonb),
    'contract','pulse_canonical_concepts_v1');
$function$;

-- ---------------------------------------------------------------------------------------------------
-- (3) Query entry point: add language-coverage-gap observability for non-English markets.
-- ---------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_stage2_supplier_search_queries(p_tenant uuid, p_product_id uuid, p_market text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE v_owns boolean; v_der jsonb; v_spec jsonb; v_terms jsonb; v_en boolean; v_gap boolean;
BEGIN
  IF p_tenant IS NULL OR p_product_id IS NULL OR coalesce(btrim(p_market),'')='' THEN
    RETURN jsonb_build_object('ok',false,'reason','missing_args'); END IF;
  SELECT EXISTS(SELECT 1 FROM public.commerce_products WHERE id=p_product_id AND user_id=p_tenant) INTO v_owns;
  IF NOT v_owns THEN RETURN jsonb_build_object('ok',false,'reason','not_owned'); END IF;
  v_der := public.fn_derive_concrete_product_identity(p_tenant, p_product_id, p_market);
  IF coalesce(v_der->>'ok','false') <> 'true' THEN RETURN v_der; END IF;
  v_spec := v_der->'match_spec';
  v_terms := public.fn_supplier_search_terms(v_spec);
  v_en := upper(p_market) = ANY (ARRAY['US','GB','UK','IE','AU','CA','NZ','SG']);
  v_gap := (v_terms->>'source' = 'SOURCE_PHRASE_FALLBACK') AND NOT v_en;
  RETURN jsonb_build_object('ok',true,'market',upper(p_market),
    'concrete_state', v_der->>'concrete_state',
    'identity_confidence', v_der->'concrete_identity'->>'identity_confidence',
    'match_spec', v_spec, 'search', v_terms,
    'language_coverage_gap', v_gap,
    'language_note', CASE WHEN v_gap THEN
      'Non-English market produced no canonical concept; the supplier query is a low-confidence source-language fallback and may under-retrieve. Extend fn_canonical_concepts for this product family.'
      ELSE NULL END,
    'page_num', 1, 'page_size', 20,
    'contract','pulse_stage2_supplier_search_queries_v2');
END; $function$;

REVOKE ALL ON FUNCTION public.fn_stage2_supplier_search_queries(uuid,uuid,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_stage2_supplier_search_queries(uuid,uuid,text) TO service_role;

-- ---------------------------------------------------------------------------------------------------
-- (4) Deterministic multilingual self-test (service_role only; mocked; no provider calls, no writes).
-- ---------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_stage2_multilingual_selftest()
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  pass int := 0; fail int := 0; results jsonb := '[]'::jsonb;
  cc jsonb; qs text[];
  -- the test exercises title -> canonical concepts -> English supplier queries end to end.
  v_dist text[]; v_terms jsonb;
BEGIN
  -- 0: accent folding is correct (deterministic, IMMUTABLE)
  IF public.fn_fold_accents('Crèche de Noël')='creche de noel'
     AND public.fn_fold_accents('Éclairé Décoration Murale')='eclaire decoration murale'
     AND public.fn_fold_accents('Iluminación Belén')='iluminacion belen'
     AND public.fn_fold_accents('Podświetlana Szopka')='podswietlana szopka'
     AND public.fn_fold_accents('Weihnachtskrippe beleuchtet')='weihnachtskrippe beleuchtet'
     THEN pass:=pass+1; results:=results||jsonb_build_object('check','0_accent_fold','pass',true);
     ELSE fail:=fail+1; results:=results||jsonb_build_object('check','0_accent_fold','pass',false,
       'got',jsonb_build_object('fr',public.fn_fold_accents('Crèche de Noël'),'es',public.fn_fold_accents('Iluminación Belén'),'pl',public.fn_fold_accents('Podświetlana Szopka'))); END IF;

  -- 1: French accented nativity -> NATIVITY_SCENE + ILLUMINATED
  cc := public.fn_canonical_concepts('Crèche de Noël lumineuse décoration murale');
  v_dist := ARRAY(SELECT x FROM jsonb_array_elements_text(cc->'distinguishing') x);
  IF 'NATIVITY_SCENE'=ANY(v_dist) AND 'ILLUMINATED'=ANY(v_dist) AND 'FORM:WALL_DECORATION'=ANY(v_dist)
     THEN pass:=pass+1; results:=results||jsonb_build_object('check','1_fr_nativity','pass',true,'dist',cc->'distinguishing');
     ELSE fail:=fail+1; results:=results||jsonb_build_object('check','1_fr_nativity','pass',false,'got',cc); END IF;

  -- 2: Spanish accented nativity -> NATIVITY_SCENE
  cc := public.fn_canonical_concepts('Belén iluminado de Navidad');
  v_dist := ARRAY(SELECT x FROM jsonb_array_elements_text(cc->'distinguishing') x);
  IF 'NATIVITY_SCENE'=ANY(v_dist) AND 'ILLUMINATED'=ANY(v_dist)
     THEN pass:=pass+1; results:=results||jsonb_build_object('check','2_es_nativity','pass',true);
     ELSE fail:=fail+1; results:=results||jsonb_build_object('check','2_es_nativity','pass',false,'got',cc); END IF;

  -- 3: Italian nativity (presepe) -> NATIVITY_SCENE
  cc := public.fn_canonical_concepts('Presepe illuminato decorazione da parete');
  v_dist := ARRAY(SELECT x FROM jsonb_array_elements_text(cc->'distinguishing') x);
  IF 'NATIVITY_SCENE'=ANY(v_dist) AND 'ILLUMINATED'=ANY(v_dist) AND 'FORM:WALL_DECORATION'=ANY(v_dist)
     THEN pass:=pass+1; results:=results||jsonb_build_object('check','3_it_nativity','pass',true);
     ELSE fail:=fail+1; results:=results||jsonb_build_object('check','3_it_nativity','pass',false,'got',cc); END IF;

  -- 4: end-to-end — a French spec expands to English nativity queries (via fn_supplier_search_terms)
  v_terms := public.fn_supplier_search_terms(jsonb_build_object(
    'product_noun', jsonb_build_array('creche','noel','lumineuse'),
    'canonical_noun', to_jsonb(ARRAY(SELECT x FROM jsonb_array_elements_text(public.fn_canonical_concepts('creche de noel lumineuse murale')->'distinguishing') x)),
    'canonical_attr_all', to_jsonb(ARRAY(SELECT x FROM jsonb_array_elements_text(public.fn_canonical_concepts('creche de noel lumineuse murale')->'distinguishing') x))));
  qs := ARRAY(SELECT x FROM jsonb_array_elements_text(v_terms->'queries') x);
  IF v_terms->>'source'='CANONICAL_EXPANSION' AND 'nativity scene'=ANY(qs)
     THEN pass:=pass+1; results:=results||jsonb_build_object('check','4_fr_to_english_query','pass',true,'queries',to_jsonb(qs));
     ELSE fail:=fail+1; results:=results||jsonb_build_object('check','4_fr_to_english_query','pass',false,'got',v_terms); END IF;

  -- 5: generality — multilingual HUMIDIFIER (non-nativity category) canonicalises and yields an English query
  cc := public.fn_canonical_concepts('Luftbefeuchter mit LED');  -- DE
  v_dist := ARRAY(SELECT x FROM jsonb_array_elements_text(cc->'distinguishing') x);
  v_terms := public.fn_supplier_search_terms(jsonb_build_object(
    'product_noun', jsonb_build_array('luftbefeuchter'),
    'canonical_noun', to_jsonb(v_dist), 'canonical_attr_all', to_jsonb(v_dist)));
  qs := ARRAY(SELECT x FROM jsonb_array_elements_text(v_terms->'queries') x);
  IF 'HUMIDIFIER'=ANY(v_dist) AND 'humidifier'=ANY(qs)
     THEN pass:=pass+1; results:=results||jsonb_build_object('check','5_humidifier_generality','pass',true,'queries',to_jsonb(qs));
     ELSE fail:=fail+1; results:=results||jsonb_build_object('check','5_humidifier_generality','pass',false,'got',jsonb_build_object('dist',to_jsonb(v_dist),'terms',v_terms)); END IF;

  -- 6: English behaviour unchanged (folding no-op; ASCII title still canonicalises)
  cc := public.fn_canonical_concepts('LED Lighted Nativity Scene Wall Decoration');
  v_dist := ARRAY(SELECT x FROM jsonb_array_elements_text(cc->'distinguishing') x);
  IF 'NATIVITY_SCENE'=ANY(v_dist) AND 'ILLUMINATED'=ANY(v_dist) AND 'FORM:WALL_DECORATION'=ANY(v_dist)
     THEN pass:=pass+1; results:=results||jsonb_build_object('check','6_english_unchanged','pass',true);
     ELSE fail:=fail+1; results:=results||jsonb_build_object('check','6_english_unchanged','pass',false,'got',cc); END IF;

  -- 7: cross-language matching still correct — French supplier title matches German-sourced nativity spec
  IF (public.fn_market_supplier_match(
        jsonb_build_object('product_noun',jsonb_build_array('beleuchtete','krippen','wanddekoration'),
          'canonical_noun',jsonb_build_array('NATIVITY_SCENE','ILLUMINATED','FORM:WALL_DECORATION'),
          'canonical_attr_all',jsonb_build_array('NATIVITY_SCENE','ILLUMINATED','FORM:WALL_DECORATION')),
        'Crèche de Noël lumineuse à LED, décoration murale', 'Decoracion', 'Z1', false)->>'market_supplier_match')
      IN ('STRONG_SAME_PRODUCT','EXACT_CONFIRMED')
     THEN pass:=pass+1; results:=results||jsonb_build_object('check','7_cross_language_match','pass',true);
     ELSE fail:=fail+1; results:=results||jsonb_build_object('check','7_cross_language_match','pass',false); END IF;

  RETURN jsonb_build_object('suite','fn_stage2_multilingual_selftest','pass',pass,'fail',fail,'ok',(fail=0),'results',results);
END; $function$;

REVOKE ALL ON FUNCTION public.fn_stage2_multilingual_selftest() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_stage2_multilingual_selftest() TO service_role;
