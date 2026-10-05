# STRATELOQ — Pulse SaaS Social Creative Quality Proof

**Unit:** STRATELOQ-CREATIVE-INTELLIGENCE-QUALITY-PROOF-001
**Verdict:** `PASS_READY_FOR_FOUNDER_CREATIVE_REVIEW`

The full Creative Intelligence first-slice pipeline now runs **end to end against live providers**: the
n8n runtime executes the credential-bound Gemini text-to-image executor, a real PNG is produced and
stored, an actual-image Gemini vision Judge inspects the pixels and scores 11 dimensions, and the bounded
regeneration loop runs to a terminal verdict. Three distinct, truth- and asset-validated Pulse concepts
(A, B, C) were each generated and judged on their **actual rendered images** through the locked quality
policy. **No quality threshold was weakened, no image or score was fabricated, nothing was published,
and advertising spend was $0.** Of the three concepts, **0 reached PASS — all three terminally REJECTED**
on honest, pixel-level defects (see §12–14). The proof is complete and the three results are ready for
founder creative review; no winner was auto-selected.

The earlier provider block (sandbox proxy refusing the n8n/Supabase webhooks with 403) is resolved:
generation and judging execute **server-side inside the n8n runtime** via the n8n MCP, so the sandbox
proxy is never on the path. `PASS_PARTIAL_PROVIDER_BLOCK` no longer applies.

---

## 1. EXECUTOR VERIFICATION
n8n **"Strateloq - SaaS Text-to-Image Executor"** (`017awosxICFCc91G`) verified executable: founder bound
the existing **Google Gemini (PaLM) API** credential on *Gemini Generate* and the existing **Supabase API**
credential on *Upload To Supabase Storage* (Claude did not create, replace, expose, export or print either).
The prior upload bug (`sendBody` missing → 0-byte object) stays fixed (`/sendBody=true`). Workflow run
**manual only**; **not published, no schedule/recurring trigger created**. The Monday-only intelligence scan
is untouched. Graph: Executor Webhook → Build Gemini Request → Gemini Generate (`gemini-2.5-flash-image`)
→ Normalize Output → Has Image? → Upload To Supabase Storage (`pulse-generated-media`) → Result.

## 2. CLAUDE/AGENT → n8n vs n8n-RUNTIME → PROVIDER (reachability)
Two different paths, deliberately distinguished:
- **CLAUDE → n8n webhook (direct HTTP):** still blocked by the sandbox outbound proxy (403 CONNECT to
  `tradingb.app.n8n.cloud`). Not used.
- **n8n runtime → Gemini / Supabase (server-side):** **WORKS.** Invoked via the n8n MCP `execute_workflow`,
  the runtime itself calls Gemini and Supabase. This is the path that matters, and it executed the
  credential-bound workflow successfully 9 times.

## 3. n8n → GEMINI PROOF
Every generation run reached Gemini and returned a usage record from `gemini-2.5-flash-image`
(`generateContent`, `responseModalities:["IMAGE"]`), e.g. `candidatesTokensDetails:[{modality:"IMAGE",
tokenCount:1290}]`, `serviceTier:"standard"`. Not an HTTP-200 assumption — a real image payload came back
each time.

## 4. GEMINI → ACTUAL IMAGE PROOF
`Normalize Output` extracted real base64 image bytes (`mime image/png`) on every run and `Has Image?`
routed TRUE (branch counts `[1,0]`). Nine distinct PNGs were produced (3 per concept).

## 5. SUPABASE STORAGE PROOF
Each image uploaded to bucket `pulse-generated-media` under `saas-social/ci-<job>-<exec>.png` with
HTTP 200 **and a real object body** `{Key, Id}` (non-empty — the 0-byte regression does not recur).
Objects are retrievable: 7-day signed delivery URLs were minted via the existing
**"Pulse - Sign Storage URL"** workflow (`H9JS6me4vCya0hFQ`) — see §12–14.

## 6. ACTUAL-IMAGE JUDGE PROOF
n8n **"Strateloq - Creative Quality Judge (Vision)"** (`1Of6aaThBsnorYCS`) downloads the stored object,
sends the **actual image bytes** to `gemini-2.5-flash` vision with a strict 11-dimension JSON rubric, and
returns real scores. Proof it inspects pixels, not metadata: it independently caught rendered-text typos
invisible in any prompt/metadata — "and and" (B att.1), "to to" (B att.2), "market market" (B att.3) — and
low-contrast body text (C att.3). `fn_ci_quality_judge` refuses to score without a real image ref and a
`GENERATED` row (self-test `judge_requires_actual_image`), so a PASS on spec/success alone is impossible.

## 7. CONCEPT A — "Signal to Action" (typographic convergence minimalism)
`c67917c4` · angle PROBLEM_SOLUTION · headline "Turn market signals into action." · CTA "Discover Pulse".
Truth gate PASS, asset integrity PASS (abstract; no fabricated UI/logo). Bounded loop, all actual images:

| Attempt | Image | Overall | Min dim | Verdict |
|---|---|---|---|---|
| 1 | `ci-A2-30340.png` | 74.3 | 30 | REVISE (rendered typo) |
| 2 | `ci-A3-30342.png` | 76.2 | 20 | REVISE (ORIGINALITY 20) |
| 3 | `ci-A4-30344.png` | 80.8 | 30 | **REJECT** (ORIGINALITY 30; BRAND_FIDELITY 75<80) |

**Terminal: REJECT.** Never cleared the 70 floor (ORIGINALITY/TYPOGRAPHY) across 3 attempts.
Final image (signed, 7-day):
`https://nxaunmyihhjixxxljcqt.supabase.co/storage/v1/object/sign/pulse-generated-media/saas-social/ci-A4-30344.png?token=eyJraWQiOiJjODVjNjRhMy1kZjEzLTRkNDUtYjQ0ZS0zZGQ3NWQzZTk5NDQiLCJhbGciOiJIUzI1NiJ9.eyJ1cmwiOiJwdWxzZS1nZW5lcmF0ZWQtbWVkaWEvc2Fhcy1zb2NpYWwvY2ktQTQtMzAzNDQucG5nIiwic2NvcGUiOiJkb3dubG9hZCIsImlhdCI6MTc5MTE3MDQyOSwiZXhwIjoxNzkxNzc1MjI5fQ.3lvb3RLsm2KgVimF0n935FfVQOz_ZBfs2sH0yAFxkrs`

## 8. CONCEPT B — "Editorial Intelligence Brief" (editorial split-layout)
`14c2ea81` · angle USE_CASE · headline "See what your market is doing — and what to do about it." ·
CTA "Explore Pulse". Truth gate PASS, asset integrity PASS. Bounded loop, all actual images:

| Attempt | Image | Overall | Min dim | Verdict |
|---|---|---|---|---|
| 1 | `ci-B1-30346.png` | 84.2 | 40 | REVISE (headline "and and"; ORIGINALITY 50) |
| 2 | `ci-B2-30348.png` | 79.4 | 60 | REVISE (headline "to to"; BRAND_FIDELITY 65<80) |
| 3 | `ci-B3-30350.png` | 80.4 | 60 | **REJECT** (headline "market market"; TYPOGRAPHY 60, ORIGINALITY 60) |

**Terminal: REJECT.** Gemini reinserted a different duplicated-word typo into the long headline on every
attempt. Final image (signed, 7-day):
`https://nxaunmyihhjixxxljcqt.supabase.co/storage/v1/object/sign/pulse-generated-media/saas-social/ci-B3-30350.png?token=eyJraWQiOiJjODVjNjRhMy1kZjEzLTRkNDUtYjQ0ZS0zZGQ3NWQzZTk5NDQiLCJhbGciOiJIUzI1NiJ9.eyJ1cmwiOiJwdWxzZS1nZW5lcmF0ZWQtbWVkaWEvc2Fhcy1zb2NpYWwvY2ktQjMtMzAzNTAucG5nIiwic2NvcGUiOiJkb3dubG9hZCIsImlhdCI6MTc5MTE3MDQzNiwiZXhwIjoxNzkxNzc1MjM2fQ.wIhDOHF6YBAum-exLlCsGZpIkLKYMeZlxkamoiOzQ0k`

## 9. CONCEPT C — "From Noise to Clarity" (before→after transformation)
`c2bcd885` · angle BENEFIT_OUTCOME · headline "From market noise to your next move." · CTA "Start with Pulse".
Truth gate PASS, asset integrity PASS. Bounded loop, all actual images:

| Attempt | Image | Overall | Min dim | Verdict |
|---|---|---|---|---|
| 1 | `ci-C1-30353.png` | **86.7** | 50 | REVISE (clean text; only ORIGINALITY 50) |
| 2 | `ci-C2-30355.png` | 84.2 | 60 | REVISE (ORIGINALITY 60 — ECG metaphor "common") |
| 3 | `ci-C3-30357.png` | 72.5 | 40 | **REJECT** (ORIGINALITY 40; READABILITY 55<80, BRAND_FIDELITY 70<80) |

**Terminal: REJECT.** The highest-scoring single image of the whole unit (att.1, 86.7) was blocked by one
dimension (ORIGINALITY 50); the originality-chasing regenerations regressed readability. Signed URLs
(7-day) — terminal and best variant:
- Terminal `ci-C3`:
`https://nxaunmyihhjixxxljcqt.supabase.co/storage/v1/object/sign/pulse-generated-media/saas-social/ci-C3-30357.png?token=eyJraWQiOiJjODVjNjRhMy1kZjEzLTRkNDUtYjQ0ZS0zZGQ3NWQzZTk5NDQiLCJhbGciOiJIUzI1NiJ9.eyJ1cmwiOiJwdWxzZS1nZW5lcmF0ZWQtbWVkaWEvc2Fhcy1zb2NpYWwvY2ktQzMtMzAzNTcucG5nIiwic2NvcGUiOiJkb3dubG9hZCIsImlhdCI6MTc5MTE3MDQ0MywiZXhwIjoxNzkxNzc1MjQzfQ.mivpDATTaZT8E5Vu5TTBvaWz8ZculYjvRxKh33qN_Ek`
- Best variant `ci-C1`:
`https://nxaunmyihhjixxxljcqt.supabase.co/storage/v1/object/sign/pulse-generated-media/saas-social/ci-C1-30353.png?token=eyJraWQiOiJjODVjNjRhMy1kZjEzLTRkNDUtYjQ0ZS0zZGQ3NWQzZTk5NDQiLCJhbGciOiJIUzI1NiJ9.eyJ1cmwiOiJwdWxzZS1nZW5lcmF0ZWQtbWVkaWEvc2Fhcy1zb2NpYWwvY2ktQzEtMzAzNTMucG5nIiwic2NvcGUiOiJkb3dubG9hZCIsImlhdCI6MTc5MTE3MDQ0NywiZXhwIjoxNzkxNzc1MjQ3fQ.y3zn0jMZ2IZYzku_l2nsotnQmIb-Q6i1aVxbxQNsZf4`

## 10. REGENERATION HISTORY
Each concept ran the full bounded loop: initial generation + up to 2 Judge-fed regenerations (hard cap 3
attempts via CHECK), each regeneration prompt rewritten from the prior attempt's `visible_weaknesses` /
`recommended_corrections`. 9 generations, 9 actual-image evaluations total. No 4th attempt is possible
(constraint + self-test `attempt_hard_capped_at_3`).

## 11. AUTHORITATIVE ASSETS USED + TRUTH/BRAND VALIDATION
Only one authoritative asset exists for this tenant: the founder-approved Pulse **TAGLINE**
(`creative_brand_assets`, `authoritative=true, approval_state=APPROVED`). No authoritative LOGO/UI_SCREENSHOT
is registered, so **Brand Asset Lock forced abstract, non-factual treatment** — every prompt forbids product
UI, dashboards, data charts, numbers, logos, testimonials, badges, awards and fabricated metrics, and renders
"Pulse" as styled text only (never a logo graphic). Current public brand **PULSE** retained (no visual
rebrand to Strateloq; "Pulse" presented as an existing SaaS platform, never "Building Pulse"). All 9 images:
`truth_safety_pass=true`, `fabrication_detected=false`. `fn_ci_concept_asset_integrity` would REJECT any
concept declaring a real asset class without an approved authoritative row (self-test
`fabricated_asset_rejects`).

## 12. QUALITY SCORES — COMPARISON (actual-image, 0–100, locked policy)
Locked bar (unchanged): no dimension <70; weighted overall ≥80; critical dims BRAND_FIDELITY, ASSET_FIDELITY,
TRUTH_SAFETY, READABILITY each ≥80; fabrication/truth-violation ⇒ REJECT. Terminal attempts:

| Concept | Overall | Lowest dim(s) | Critical <80 | Terminal |
|---|---|---|---|---|
| A `ci-A4` | 80.8 | ORIGINALITY 30 | BRAND_FIDELITY 75 | REJECT |
| B `ci-B3` | 80.4 | TYPOGRAPHY 60, ORIGINALITY 60 | — | REJECT |
| C `ci-C3` | 72.5 | ORIGINALITY 40 | READABILITY 55, BRAND_FIDELITY 70 | REJECT |

Best single image across the unit: **C att.1 = 86.7** (blocked only by ORIGINALITY 50). The self-test case
`good_image_passes` proves the bar is clearable (a strong synthetic image PASSes), so the 0/3 result is a
genuine quality outcome, not an unreachable threshold.

## 13. PROVIDER / MODEL USED
Generation: **Google Gemini `gemini-2.5-flash-image`** (text-only parts → IMAGE). Vision judging:
**Google Gemini `gemini-2.5-flash`** (inline image + strict JSON rubric). Both via the credential-bound
n8n runtime. No OpenAI image call (gpt-image-1 remains billing-blocked and was not used).

## 14. GENERATION COSTS
9 image generations × ~$0.039 (1290 image tokens each) = **$0.351** total. Judge vision calls
(`gemini-2.5-flash`, ~0.6k–3k tokens each) are fractions of a cent. **Advertising spend: $0.**

## 15. PRODUCT ASSET LOCK REGRESSION
`fn_creative_quality_review('IMAGE_ASSET', …)` unchanged (still machine gates with
`human_approval_required=true, launch_safe=false`); self-test `product_asset_lock_regression_intact` passes.
The additive SaaS/BUSINESS_SELF mode does not weaken the CUSTOMER_PRODUCT preflight/quality path.

## 16. TENANT / SECURITY TESTS
`fn_ci_quality_proof_selftest` **16/16** (rolled back): concepts persist, distinctness enforced, Judge
requires actual image, good image PASSes, low-quality cannot PASS, critical-dimension failure blocks PASS,
regeneration capped at 2 then REJECT, 4th attempt constraint-blocked, rejected concept not approvable,
fabricated authoritative asset REJECT, authoritative asset traces, truth violation REJECT, owner reads own
concept, cross-tenant read rejected, Product Asset Lock regression intact. All new tables tenant-scoped with
RLS SELECT-own + function-layer isolation (`fn__ci_actor_tenant`); all RPCs SECURITY DEFINER
`search_path=''`; privileged functions revoked from anon/public. Security advisors: **0 ERROR** (4 WARN /
1 INFO baseline — unchanged by this unit).

## 17. PUBLISHING = ZERO
This unit writes nothing to `social_publishing_requests` / `social_post_results` and never touches the paid
lane. Live checks today: publish requests = 0, post results = 0. No Facebook/Instagram/Meta/ads/scheduling/
autonomous publishing of any kind. Unit ends at **founder creative review**; **no winner auto-selected**.

## 18. PAID SPEND = $0
`spend_reservations` created today = **0**; no campaign/ad set/ad; `marketing_spend_authority` unchanged.
Advertising spend attributable to this unit: **$0**.

## 19. FILES / WORKFLOWS / MIGRATIONS CHANGED
- `supabase/migrations/mig_346_creative_intelligence_quality_proof.sql` (applied earlier; unchanged this slice).
- `docs/STRATELOQ-CREATIVE-INTELLIGENCE-QUALITY-PROOF.md` (this report — updated to live results).
- n8n (runtime config, not repo code): executor `017awosxICFCc91G` credentials bound by founder + upload
  `sendBody=true`; Judge `1Of6aaThBsnorYCS` used as built; signing `H9JS6me4vCya0hFQ` reused. No schedule,
  nothing published.
- Runtime records (not code): 9 `creative_concept_generations` (GENERATED, actual images) + 9
  `creative_quality_evaluations`; concepts A/B/C `final_verdict=REJECT`.

## 20. GIT COMMIT + FINAL VERDICT
Branch `claude/brave-knuth-uxowfg`: `8e8b6b5` (mig_346) + this report's commit.

**`PASS_READY_FOR_FOUNDER_CREATIVE_REVIEW`** — the Creative Intelligence quality pipeline is proven end to
end against live providers: real image generation, actual-image 11-dimension vision judging, bounded
regeneration, truth/asset/Brand-Asset-Lock gates, tenant isolation and the locked threshold policy all
executed exactly as specified, 16/16 self-tests, 0 security errors, nothing published, $0 ad spend, and no
fabricated image or score. The creative outcome is honest and unflattering: **0 of 3 concepts PASS — all
three terminally REJECTED** on real pixel defects (recurring Gemini headline-typos and persistent
sub-threshold ORIGINALITY; C's best image missed only on ORIGINALITY at 86.7). No thresholds were lowered to
force a PASS and no winner was selected. The three results + full score history are ready for the founder's
creative review and decision.
