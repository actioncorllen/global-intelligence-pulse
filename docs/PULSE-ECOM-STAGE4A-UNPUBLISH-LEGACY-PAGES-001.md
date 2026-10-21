# PULSE-ECOM-STAGE4A-UNPUBLISH-LEGACY-PAGES-001

**Founder-approved: the two named legacy product pages are now UNPUBLISHED via the existing storefront
publishing lifecycle. Nothing was deleted, no other product or storefront was touched, no paid calls.
Both public URLs now resolve to NOT_FOUND (404) at the authoritative render contract.** (data change; no
migration)

## Pages unpublished (exactly two)
| Product | page_id | market | public slug / URL | before → after |
|---|---|---|---|---|
| **3 Channel Dash Cam** (`66b60d77…`) | `ae458526-3fd2-47e0-a613-3da7b7f92f11` | US | `…/functions/v1/storefront/pae4585263fd2` | PUBLISHED → **UNPUBLISHED** (published_url cleared) |
| **Kids Nightlight Projector** (`e453eed4…`) | `45af3635-6648-4a4e-8c13-ddf39dc096f2` | US | `…/functions/v1/storefront/p45af36356648` | PUBLISHED → **UNPUBLISHED** (published_url cleared) |

## How (existing lifecycle, req 2)
Used `fn_storefront_transition_state(page_id, 'APPROVED', tenant)` — the lifecycle's permitted
`PUBLISHED → APPROVED` transition, which sets `publication_state='UNPUBLISHED'` and clears
`published_url`. No raw table hacking; no new code. Both returned `status: ok, from PUBLISHED,
publication_state UNPUBLISHED, published_url null`.

## Verification (reqs 3, 6, 7)
- **DB state:** both pages `publication_state='UNPUBLISHED'`, `review_state='APPROVED'`, `published_url=NULL`.
- **Public URLs no longer serve (req 3):** `fn_public_storefront_render('pae4585263fd2')` and
  `('p45af36356648')` both return **`NOT_FOUND`** — the render gate is `publication_state <> 'PUBLISHED'
  → NOT_FOUND`, which the public storefront edge function returns to visitors as **404**. No product page
  is served and no checkout is reachable (checkout was already `CHECKOUT_NOT_CONFIGURED`; the page now
  404s entirely).
  - The real HTTP GET to the public URLs could not be run from this container (outbound blocked by the
    network policy — proxy `403 CONNECT tunnel failed` for the Supabase host). Verified instead at the
    authoritative render-contract layer the edge function depends on.
- **No collateral (req 5):** after the change, **0** of the tenant's pages remain PUBLISHED, and no other
  page's state was altered (these two were the only PUBLISHED pages). No storefront connection touched.
- **Nothing deleted / content preserved (req 4):** all **6** of the tenant's product-page rows still
  exist; `page_model` and `runtime_contract` preserved on both; the Kids Nightlight Projector's bound CJ
  supplier (`commerce_concrete_supplier_resolution`, 1 binding) preserved; product assets, historical
  research, ownership and audit (`updated_at`, runtime_contract state keys) all intact. Reversible: a
  `fn_storefront_transition_state(..., 'PUBLISHED', …)` re-publishes from APPROVED.

## Status
| Req | Result |
|---|---|
| 1 identify page records + URLs | **PASS** |
| 2 PUBLISHED → UNPUBLISHED via existing lifecycle | **PASS** |
| 3 public URLs no longer serve / checkout blocked (404) | **PASS** (authoritative render NOT_FOUND; live HTTP not reachable from container) |
| 4 preserve content/assets/bindings/research/ownership/audit; no delete | **PASS** |
| 5 no other products/storefronts changed | **PASS** (0 other PUBLISHED touched) |
| 6 verify both statuses + URL inaccessibility | **PASS** |
| 7 fix → test → re-test | **PASS** |

**Overall: PASS.** Both legacy pages are UNPUBLISHED and 404 at the render contract; everything else
preserved; reversible. No paid calls, no unrelated changes. STOP — no roadmap stage advanced.
