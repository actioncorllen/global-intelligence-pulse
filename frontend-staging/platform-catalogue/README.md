# Shared Catalogue frontend package — STAGED, NOT DEPLOYED (W0.05)

This directory holds the prepared "Shared Catalogue | My Research" frontend package for the Lovable app.
It is **staged here for durable version control only**. It is **not wired into any build** in this repository
(this repo is the Supabase/backend/DR codebase and has no `src/` frontend build), so committing it here
**cannot change the deployed site, cannot activate catalogue data, and cannot enable billing.**

## Safety
- Every data value is fetched through authenticated Supabase RPCs; there is **no tenant id, provider key,
  or research logic client-side**.
- The live catalogue stays **empty** until provider display rights are cleared (all `catalogue_source_rights`
  dimensions are FALSE) and publication runs — the UI renders honest empty states until then.
- Browsing/adoption consume **0 research actions** (server-enforced); only explicit deeper research is metered.
- No Stripe/billing code is introduced.

## Deployment (requires Lovable credits — do NOT deploy from here)
Follow `W0.05_DEPLOYMENT.md`: copy the 8 files into the Lovable project's `src/` at the documented
destinations, swap the parent page's `<EcommerceWorkspace/>` for `<CatalogueWorkspace/>`, typecheck, and
smoke-test. Deployment is performed in Lovable, not in this repository.

## Files
| File | Lovable destination |
|---|---|
| platform-catalogue-contract.ts | src/lib/business-discovery/ |
| catalogue-actions-contract.ts | src/lib/business-discovery/ |
| opportunity-classification.ts | src/lib/business-discovery/ |
| use-platform-catalogue.ts | src/hooks/ |
| use-catalogue-actions.ts | src/hooks/ |
| CatalogueCountrySelector.tsx | src/components/business-discovery/ |
| CatalogueOpportunityCard.tsx | src/components/business-discovery/ |
| CatalogueWorkspace.tsx | src/components/business-discovery/ |
| W0.05_DEPLOYMENT.md | (manifest; stays with the package) |

All RPC argument names are validated against the deployed Supabase function signatures (see the manifest).
