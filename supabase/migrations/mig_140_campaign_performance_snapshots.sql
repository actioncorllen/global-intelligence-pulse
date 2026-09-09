-- PULSE-ECOM-P14-PERFORMANCE-INTELLIGENCE-001
-- Provider-independent canonical campaign performance snapshot.
-- Every row carries a source classification. Fixtures are explicitly flagged and
-- can NEVER produce an executable recommendation.
CREATE TABLE IF NOT EXISTS public.campaign_performance_snapshots (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id             uuid NOT NULL,
  campaign_execution_id uuid,
  campaign_draft_id     uuid,
  platform              text NOT NULL DEFAULT 'META',
  level                 text NOT NULL DEFAULT 'CAMPAIGN',
  platform_campaign_id  text,
  platform_object_id    text,
  spend                 numeric,
  impressions           bigint,
  reach                 bigint,
  frequency             numeric,
  clicks                bigint,
  link_clicks           bigint,
  landing_page_views    bigint,
  add_to_cart           bigint,
  initiate_checkout     bigint,
  purchases             bigint,
  revenue               numeric,
  spend_currency        text,
  revenue_currency      text,
  source_class          text NOT NULL DEFAULT 'UNKNOWN',
  is_fixture            boolean NOT NULL DEFAULT false,
  purchase_source_verified boolean NOT NULL DEFAULT false,
  window_start          timestamptz,
  window_end            timestamptz,
  provenance            jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at            timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT cps_level_chk CHECK (level IN ('CAMPAIGN','ADSET','AD')),
  CONSTRAINT cps_source_chk CHECK (source_class IN
    ('REAL_OBSERVED','PLATFORM_REPORTED','DERIVED','ESTIMATED','FIXTURE','UNKNOWN'))
);
CREATE INDEX IF NOT EXISTS cps_tenant_idx ON public.campaign_performance_snapshots (tenant_id, platform, level);
CREATE INDEX IF NOT EXISTS cps_exec_idx ON public.campaign_performance_snapshots (campaign_execution_id);
ALTER TABLE public.campaign_performance_snapshots ENABLE ROW LEVEL SECURITY;
-- RLS on, no permissive policy: service role / SECURITY DEFINER only.
