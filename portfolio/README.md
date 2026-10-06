# STRATELOQ — Upwork Portfolio Visual Evidence Pack (001)

Sanitized, repository-grounded portfolio evidence for **Strateloq** — an autonomous
e-commerce intelligence, decisioning and creative platform.

- **Interactive pack (view / screenshot / share):** `STRATELOQ-VISUAL-EVIDENCE-PACK.html`
  (published to a private Claude artifact — link is in the delivery message).
- **Creative stills (upload-ready):** `assets/`
- **Standalone diagrams (upload-ready):** `visuals/`

Every figure traces to committed repository evidence. **No credentials, secrets,
tokens, project identifiers, hostnames, or customer data appear anywhere in this pack.**

---

## 1. How to use this on Upwork

Create one portfolio project — suggested title:

> **Strateloq — Autonomous E-Commerce Intelligence & AI Creative Platform**

Suggested short description (paste and trim to taste):

> Designed and built an autonomous e-commerce operating system: it scans global
> markets for real product opportunities across six live data sources, scores each
> product × market against fail-closed economic gates, generates founder-quality ad
> creative from protected product identity with a native FFmpeg compositor, and stages
> everything for human-approved publishing. Built on a row-level-secured Postgres
> backend (93 tables, 370+ SECURITY DEFINER functions, 95 migrations), 12 edge
> functions, and 25+ automation workflows, with a documented disaster-recovery posture
> and a provider-neutral paid-access foundation.

Then attach the images below. The interactive HTML pack doubles as a **screenshot
source**: every panel is sized to be captured cleanly on its own.

---

## 2. Visual inventory (what each visual proves, and its evidence)

| # | Visual | What it demonstrates | Repository evidence |
|---|--------|----------------------|---------------------|
| 1 | Cover + headline metrics | Scope and scale of the system | `supabase/migrations` (95), `supabase/functions` (12), `dr/schema/*.sql` |
| 2 | Five-capability overview | Product breadth on one governed spine | delivery docs across `docs/` |
| 3 | System architecture (5 layers) | End-to-end design: sources → automation → backend → brains → publishing | migrations, edge functions, `dr/n8n` inventory |
| 4 | Autonomous weekly pipeline + decision bands | Scheduled orchestration and the scoring ladder | `PULSE-ECOM-MONDAY-PIPELINE-CLOSEOUT-001`, `PULSE-ECOM-UNIFIED-PRODUCT-OPPORTUNITY-DECISION-001` |
| 5 | Multi-source intelligence matrix | Real providers with truthful availability states | `STRATELOQ-…-DEEP-RESEARCH-ORCHESTRATOR-013J` |
| 6 | AI Creative Studio pipeline + real ad output | Identity-protected creative + a genuine composited ad and video frames | `…CREATIVE-STUDIO-015T/015U`, `docs/creatives/*`, `scripts/compositor/` |
| 7 | Marketing Director → publishing lineage | Strategy brain + hard organic/advertising boundary | `STRATELOQ-016A` (mig_290), `STRATELOQ-016B` (mig_291) |
| 8 | Security & governance model | RLS deny-by-default, secret-ref, fail-closed, approval gates | `dr/schema/policies.sql`, `rls_enable.sql`, migration self-tests |
| 9 | Disaster-recovery posture | Component protection matrix with RPO/RTO and honest status | `dr/runbook/DR-INVENTORY.md`, `scripts/dr/*.sh` |
| 10 | Evidence integrity panel | Explicitly separates repo-derived visuals from live-capture items | this pack |

### Real creative artifacts included (`assets/`)
These are genuine outputs of the Creative Studio for a generic test product (a galaxy
star-projector night light). They contain no brand, no PII, and no secrets.

- `creative-static-ad.jpg` — composited 9:16 static ad (final output).
- `creative-product-cutout.png` — the isolated product used as the compositor's protected source.
- `creative-video-frames.png` — six sampled frames from the generated multi-scene video.

> The full-motion MP4s live in the repo and can be uploaded to Upwork directly if you
> want motion in the portfolio (they are not copied here to keep this folder light):
> `docs/creatives/STRATELOQ-015T-nightlight-multiscene-ad.mp4` (17s multi-scene) and
> `docs/creatives/STRATELOQ-015S-nightlight-ad.mp4`.

---

## 3. Evidence integrity statement

This pack was produced by **read-only evidence extraction** from the repository. Diagrams
and matrices are reconstructions of what the code, schema and delivery records actually
contain — not mock-ups of imagined features. Numbers (table/function/migration counts,
RPO/RTO targets, decision bands, cost caps) are quoted from committed files.

Where a portfolio visual would genuinely require the **live authenticated product UI or
the automation canvas**, it was **deliberately not recreated as a fake screenshot**.
Those items are listed below as real remaining capture tasks for you.

---

## 4. Remaining external screenshot blockers (only you can capture these)

Each of these needs an authenticated session in a live system. They are the *only*
genuine blockers — everything else in the pack is complete.

| Blocker | Where to capture | What to show | Sanitize before use |
|---------|------------------|--------------|---------------------|
| **Strateloq app UI** | Live hosted front end (login) | Opportunity list, a Product/Decision card, the Creative Studio screen | Blur tenant/business names, emails, any real customer product, internal IDs |
| **n8n canvas** | n8n cloud (login) | The Monday orchestrator graph + one successful execution | Crop out the instance hostname and account menu; never open a credential node |
| **Supabase dashboard** | Supabase project (login) | Table editor (table list), RLS policies list, a logs view | Redact the project ref/URL, API keys, connection strings, any row data with PII |
| **Meta Business Suite** | Meta Business (login) | The PAUSED-only ad object; CAPI events received | Redact ad-account IDs, pixel IDs, page/business names, spend if sensitive |
| **Live storefront** | Deployed public storefront URL | The rendered conversion page | Use the generic test product; hide any real domain if not public-ready |

### Safe-capture checklist (apply to every screenshot)
1. Use the **generic test product**, never a real customer's product.
2. **Redact identifiers** — project refs, account/ad/pixel IDs, hostnames, emails, tokens, API keys.
3. **No credential screens** — never screenshot a secret/credential/env panel, even partially.
4. Prefer **structure over data** — show that a feature exists (e.g. the RLS policy *list*),
   not sensitive row contents.
5. Keep a **consistent frame** (same zoom/width) so the captures sit well beside the
   diagrams in this pack.

---

## 5. Provenance & guardrails

- Produced in a **read-only support session**; no production functionality was
  redesigned, refactored, deployed, or modified, and no production code was committed.
- Task: **STRATELOQ-UPWORK-PORTFOLIO-VISUAL-EVIDENCE-PACK-001**.
- Nothing sensitive is exposed: no credentials, secrets, tokens, project/instance
  identifiers, or customer data.
