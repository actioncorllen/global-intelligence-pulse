-- STRATELOQ cleanup: remove the ad-hoc MCP write-channel workaround helpers created during the
-- premium-video build. These were never part of the repo; they existed only on the live DB to apply
-- a couple of config writes/probes through a flaky MCP write channel. They are not referenced by any
-- production code path.
--
-- Live-apply status at authoring time:
--   * The REVOKEs below were applied live and confirmed (all three are now executable only by
--     postgres/service_role; anon/authenticated/public execute removed). This neutralizes the one
--     SECURITY DEFINER helper's privilege surface.
--   * The DROPs could NOT be applied live at authoring time: the project's `sql_drop` event triggers
--     (pgrst_drop_watch / set_graphql_placeholder) were wedging the MCP write channel so every DROP
--     timed out without committing (reads and GRANT/REVOKE statements went through fine; no DB lock
--     was involved). They should be dropped in a maintenance window when the write channel is healthy.
--     DROP IF EXISTS is idempotent and harmless on a clean replay (these functions never ship from repo).

REVOKE EXECUTE ON FUNCTION public.fn_strateloq_apply_composition_config() FROM public, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.fn_strateloq_apply_render_candidates() FROM public, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.fn_strateloq_wchan_probe() FROM public, anon, authenticated;

DROP FUNCTION IF EXISTS public.fn_strateloq_apply_composition_config();
DROP FUNCTION IF EXISTS public.fn_strateloq_apply_render_candidates();
DROP FUNCTION IF EXISTS public.fn_strateloq_wchan_probe();
