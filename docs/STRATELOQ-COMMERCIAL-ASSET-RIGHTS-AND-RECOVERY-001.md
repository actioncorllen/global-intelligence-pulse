# STRATELOQ — Commercial Asset Rights & Recovery (Canonical Rule)

**Status:** Permanent architecture rule. Applies to Product Opportunity
Intelligence, Product Card, Create Ad, Create Free Store, Add/Publish to Store,
Creative Studio, My Store, and Storefront publication.

## The rule

> Discovery does not imply publication rights.
>
> Strateloq may use public/authorized evidence to identify and evaluate product
> opportunities, but commercial publication requires a verified legitimate asset
> path. Where a discovered product lacks publishable imagery, Strateloq attempts
> supplier-authorized asset recovery, authorized-reference generation, licensed
> assets, or customer-authorized assets before publication.
>
> AI transformation must never be used as a workaround for unknown or restricted
> image rights.

Every product carries **two independent dimensions**:

1. **Opportunity quality** — demand, buyer intent, competition, economics, etc.
   (unchanged; owned by the opportunity engine).
2. **Commercial asset readiness** — whether the product can currently be
   marketed with legitimate commercial assets.

A high-quality opportunity is **not** rejected because its discovery image is
not republishable. Opportunity quality and launch readiness are separate.

## Research image vs commercial publication

`PRODUCT DISCOVERY IMAGE` (marketplace / competitor / social / eBay / Amazon /
TikTok / Meta / Google) is **research only**. It is valuable for identification,
trend evidence, competitor intelligence and product matching, but it is **never**
a storefront/ad publication asset, a customer-owned or supplier-authorized asset,
or a Gemini generation reference — unless commercial rights are independently
established.

## Canonical rights ladder (`fn_asset_rights_class`)

Asset-specific, never inferred from URL/domain/accessibility:

`CUSTOMER_OWNED` · `SUPPLIER_AUTHORIZED` · `EXPLICITLY_LICENSED` ·
`AUTHORIZED_FOR_AI_REFERENCE` · `RESEARCH_REFERENCE_ONLY` · `RIGHTS_UNKNOWN` ·
`RESTRICTED`.

`MARKETPLACE_PUBLIC_LISTING` (eBay/Amazon), competitor and social sources map to
`RESEARCH_REFERENCE_ONLY`. **CJ presence alone is not "rights cleared":** a CJ
image is `SUPPLIER_AUTHORIZED` only via an explicit supplier-product link;
otherwise the product is `SUPPLIER_ASSET_REQUIRED`.

## Canonical readiness model (`fn_product_commercial_asset_readiness`)

One authoritative contract, consumed everywhere (Product Card, My Store,
opportunity search, edge function):

| State | Meaning |
|---|---|
| `READY` | A verified publishable commercial asset exists. |
| `GENERATABLE_FROM_AUTHORIZED_REFERENCE` | An eligible authorized reference exists; the Gemini v5 pipeline may produce an identity-validated commercial image. |
| `SUPPLIER_ASSET_REQUIRED` | Supplier matched, but a supplier-authorized commercial asset has not yet been obtained (recovery required). |
| `CUSTOMER_ASSET_REQUIRED` | The customer must provide an authorized asset. |
| `UNAVAILABLE` | No legitimate commercial asset route is currently established. |
| `UNKNOWN` | Rights/provenance could not be determined reliably. |

Derived `commercial_testability`: `READY_TO_TEST` · `ASSET_GENERATION_AVAILABLE`
· `ASSET_RECOVERY_REQUIRED` · `CUSTOMER_ACTION_REQUIRED` ·
`NOT_CURRENTLY_LAUNCHABLE`.

## Gemini eligibility (server-authoritative)

Gemini generation is **only** eligible when a real usable **authorized**
reference exists (customer-owned, a supplier-authorized asset, or a resolvable
supplier primary) **and** the product is owned by the tenant. A mere supplier
identity match with no obtained asset is **not** eligible. Marketplace/
competitor/social references are never sent to Gemini. Eligibility is resolved
server-side; the browser never determines rights. The existing bounded
`IMAGE_OTHER` retry (max 2 attempts) and Product Asset Lock (mandatory
`IDENTITY_VALIDATED`) are unchanged and are never weakened to raise pass rates.

## Asset ladder (attempted in order)

A customer-owned → B verified supplier commercial asset → C authorized supplier
reference → Gemini → D explicitly licensed → E supplier asset recovery
(`SUPPLIER_ASSET_REQUIRED`) → F customer asset (`CUSTOMER_ASSET_REQUIRED`) → G no
route (`UNAVAILABLE`). Executing a live supplier (CJ) product match/asset
recovery is an external supplier-API step (via the existing CJ integration); the
readiness engine exposes the state and path without fabricating authorization.

## Contracts

- `fn_asset_rights_class(rights_state, source_provider, provenance)` — pure rights classification.
- `fn_product_commercial_rights(product)` — per-product rights summary (read-only; never overwrites provenance).
- `fn_product_commercial_asset_readiness(product, market)` — canonical readiness (mig_324/326/327).
- `fn_product_commercial_readiness_badge(product, market)` — concise label/reason for opportunity & search cards.
- `fn_monday_top_opportunities` — each opportunity card exposes `commercial_assets` (the badge).

Rights are never fabricated. `"copyright free" / "unrestricted" / "rights cleared"`
are used only when evidence supports that exact claim; otherwise the state is
`UNKNOWN` / `CUSTOMER_ASSET_REQUIRED` / `SUPPLIER_ASSET_REQUIRED` / `UNAVAILABLE`.
