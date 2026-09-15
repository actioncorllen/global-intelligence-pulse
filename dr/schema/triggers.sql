-- STRATELOQ DR SCHEMA SNAPSHOT (independent logical schema backup; NO secrets, NO customer data)
-- Source of truth: live Supabase public schema. See dr/runbook/RECOVERY-RUNBOOK.md for restore order.

-- ORDER 6: triggers

CREATE TRIGGER auth_event_no_mutate BEFORE DELETE OR UPDATE ON public.auth_event FOR EACH ROW EXECUTE FUNCTION fn_guard_auth_event_immutable();
CREATE TRIGGER business_profiles_updated_at BEFORE UPDATE ON public.business_profiles FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER commerce_product_opportunities_updated_at BEFORE UPDATE ON public.commerce_product_opportunities FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER commerce_products_updated_at BEFORE UPDATE ON public.commerce_products FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER commerce_products_visibility BEFORE INSERT ON public.commerce_products FOR EACH ROW EXECUTE FUNCTION fn_stamp_commerce_visibility();
CREATE TRIGGER commerce_signals_updated_at BEFORE UPDATE ON public.commerce_signals FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER commerce_signals_visibility BEFORE INSERT ON public.commerce_signals FOR EACH ROW EXECUTE FUNCTION fn_stamp_commerce_visibility();
CREATE TRIGGER commerce_supplier_products_touch BEFORE UPDATE ON public.commerce_supplier_products FOR EACH ROW EXECUTE FUNCTION fn_commerce_supplier_products_touch();
CREATE TRIGGER discovery_run_commerce_finalize AFTER UPDATE OF run_status ON public.discovery_runs FOR EACH ROW WHEN (((new.run_status = 'succeeded'::text) AND (old.run_status IS DISTINCT FROM 'succeeded'::text))) EXECUTE FUNCTION fn_discovery_run_commerce_finalize();
CREATE TRIGGER discovery_state_protect_member_id BEFORE UPDATE ON public.discovery_state FOR EACH ROW EXECUTE FUNCTION fn_guard_discovery_state_member_id();
CREATE TRIGGER discovery_state_updated_at BEFORE UPDATE ON public.discovery_state FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER founding_applications_updated_at BEFORE UPDATE ON public.founding_applications FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER invitation_updated_at BEFORE UPDATE ON public.invitation FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER member_actions_canonical_status BEFORE INSERT ON public.member_actions FOR EACH ROW EXECUTE FUNCTION fn_member_actions_canonical_status();
CREATE TRIGGER member_actions_updated_at BEFORE UPDATE ON public.member_actions FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER member_business_dna_updated_at BEFORE UPDATE ON public.member_business_dna FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER member_generated_content_updated_at BEFORE UPDATE ON public.member_generated_content FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER member_opportunities_updated_at BEFORE UPDATE ON public.member_opportunities FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER member_protect_fields BEFORE UPDATE ON public.member FOR EACH ROW EXECUTE FUNCTION fn_guard_member_protected_fields();
CREATE TRIGGER member_updated_at BEFORE UPDATE ON public.member FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER product_acquisitions_updated_at BEFORE UPDATE ON public.product_acquisitions FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER roadmap_items_updated_at BEFORE UPDATE ON public.roadmap_items FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER trg_mcd_touch BEFORE UPDATE ON public.marketing_campaign_drafts FOR EACH ROW EXECUTE FUNCTION tg_marketing_campaign_drafts_touch();
CREATE TRIGGER trg_mce_touch BEFORE UPDATE ON public.marketing_campaign_executions FOR EACH ROW EXECUTE FUNCTION tg_marketing_campaign_executions_touch();
