# Founding-Member Onboarding & Beta Acceptance (2026-11-10)

Verification of the real founding-member lifecycle + operational runbook for the first five members. **No test
invitation sent to any real applicant; no account activated in production; no signup/billing/paid refresh enabled.**
All checks are backend/API or rolled-back fixtures; live-browser steps are flagged as founder-device.

## Stage 1 — Founding-member lifecycle: **PASS (backend end-to-end)**
Verified the actual workflow (not just security functions) via a rolled-back forward trace with a real
email-confirmed, no-member auth user + a synthetic application, plus the 12/12 access-control self-test.

| # | Check | Result | Evidence |
|---|---|---|---|
| 1 | Public visitors apply without an account | **PASS** | `fn_submit_founding_application` → "received, no account/workspace created"; `member` not created |
| 2 | Applications enter the founder queue | **PASS** | row persists `status='new'`; `list-issuable-applications` edge is the queue |
| 3 | Founder can approve/reject | **PASS** | approval = creating an unowned `business_profile` for the application + issuing an invitation; rejects stay non-invitable |
| 4 | Only approved applicants get invitations | **PASS** | `issue_invitation` requires the application + exactly one **unowned** `business_profile` + no member + no prior discovery |
| 5 | Invitation generated & delivered via authorized flow | **PARTIAL** | `issue-invitation` edge (admin/service-role-gated) generates the token + SHA-256 hash + `issue_invitation` and returns the invite link; **no email provider is wired — the founder delivers the link** (see Stage 4) |
| 6 | Invitations bound to the intended email | **PASS** | `bound_email` stored; `accept_invitation` rejects unless the auth email matches |
| 7 | Invalid/expired/consumed/revoked fail safely | **PASS** | 12/12 self-test (expired/revoked/consumed/wrong-email/bad-token all rejected) |
| 8 | Approved members can activate | **PASS** | `accept_invitation` → `accepted/provisioned` |
| 9 | Members receive the ecommerce workspace + entitlements | **PARTIAL** | acceptance provisions **member + discovery_state** (workspace shell) ✅, but the **ecommerce_monthly COMP entitlement is a SEPARATE grant** (both live members: `granted_by "internal COMP backfill"`) — must be a founding-onboarding step (Stage 4/5) |
| 10 | No applicant can bypass approval | **PASS** | no self-provision write policy; anon can't issue/accept; invitation required |
| 11 | Tenant & country isolation hold after onboarding | **PASS** | member is `auth_user_id`-scoped; Explorer/workspace market-scoped (verified earlier: DE 9 / GB 20; cross-tenant `NOT_AUTHORIZED`) |
| 12 | Founder administration protected | **PASS** | issue/accept are admin/service-role only; RLS deny-all on sensitive tables; overbroad grants revoked |

## Stage 2 — Customer workspace entry (backend verified; live UI = founder-device)
Backend contracts confirmed (prior turns, same build): Dashboard (`fn_ecommerce_workspace_intelligence`), Product
Discovery + Explorer v5 (9 visible/20–23 pending, image-gated), country selector (market isolation), Recommendations
(tiered, accurate identity), product detail drawer (identity + asset_lock), My Store (`fn_hosted_store_get`), Create
Free Store (`fn_product_card_create_store`), My Campaigns (marketing/campaign backend present). Restricted/future
categories stay protected by PAL + the image gate + founding-member-only access. **Live in-browser render of each is
a founder-device check.** Paid Refresh Discovery / billing / signup remain inactive.

## Stage 3 — End-to-end acceptance
The chain **Application → Approval → Invitation → Activation → Sign-in → Product Discovery → Product Detail → Add
Product → My Store** is verified across: the Stage-1 lifecycle trace (through activation + workspace), the live
Explorer/recommendations/drawer reads, and the persisted Add-Product → My Store integrity check (exact identity,
tenant/market isolation, image rights/PAL, one store, no duplicate products, page UNPUBLISHED). **Sign-in and the
in-browser journey are founder-device** (strateloq.com is unreachable from this environment and holds no founder
credentials). No storefront published, no order created.

## Stage 4 — Verified blockers (internally controllable)
No code **defect** was found in the lifecycle. Two operational items:
1. **Entitlement grant (required):** a new founding member who activates has a workspace shell but **no
   `ecommerce_monthly` entitlement** until one is granted (COMP). This is included as an explicit onboarding step in
   Stage 5. It can optionally be automated (grant COMP on founding-member activation), but auto-comping every member
   is a **commercial/policy decision** — not deployed without founder approval (and it would not widen signup or add
   paid obligations). For five members a manual COMP grant is trivial and keeps control with the founder.
2. **Invitation email delivery (manual):** the `issue-invitation` edge returns the invite link for the founder to
   send; no email provider is wired. Fine for five members (founder emails the links); automated email is an optional
   future enhancement, not a launch blocker.

## Stage 5 — First five founding members: operational runbook
1. **Application review:** open the founder queue (`list-issuable-applications` / `founding_applications` where
   `status='new'`; there are 6 real pending applications). For each chosen applicant, verify work email + fit.
2. **Approve + invite:** create the applicant's `business_profile` (approval marker) and run the **issue-invitation**
   edge (founder/admin auth) → it returns a one-time invite link (14-day expiry, bound to the email). **Deliver the
   link to that exact email only.** Do not reuse links or send to third parties.
3. **Activation:** the applicant signs up at **https://strateloq.com** with the **same email**, confirms it, and opens
   the invite link → **accept-invitation** activates (member + discovery_state). **Then grant the `ecommerce_monthly`
   COMP entitlement** for that member (the Stage-4 step) so workspace entitlements are complete.
4. **First-login checklist (member):** Dashboard loads · country selector · Product Discovery shows image-gated
   products · open a product drawer · Add a product to My Store · (optional) Create Free Store · My Campaigns nav.
   Refresh Discovery shows the "not activated / pricing not set" state (correct — paid refresh stays off).
5. **Product Discovery acceptance tasks (member):** pick a market, review 3 products' evidence, add one to My Store,
   confirm exact product identity + image + that image-pending products are not shown as available.
6. **Feedback collection:** capture per-member notes on discovery relevance, image coverage, clarity of the
   "awaiting images" state, and any blocker; route to the founder roadmap.
7. **Security checks per account:** confirm the member sees only their own tenant data (isolation), market-scoped
   evidence, PAL enforced (no commercial use of reference images), one store per tenant, and no access to other
   members' applications or admin functions.

**Do not issue invitations without founder approval of the specific applicants.**

## Final report
1. **Lifecycle:** **PASS** (backend end-to-end), with two PARTIALs (email delivery manual; entitlement a separate
   grant) — both operational, not defects.
2. **Tests performed:** rolled-back forward lifecycle trace (application→approval→invitation→validate→activation→
   workspace); 12/12 access-control self-test; `issue-invitation` edge inspection (token/hash/admin-gated, no email
   provider); live workspace + persisted Add-Product/My-Store integrity (prior turns). Evidence in-line above.
3. **Defects corrected/deployed:** none required (no code defect; nothing deployed).
4. **Remaining founder-device checks:** in-browser at strateloq.com signed in — sign-in, dashboard, discovery,
   country selector, drawer, Add Product → My Store, Create Free Store, My Campaigns, mobile, Refresh modal state.
5. **Can the first five be safely invited?** **Yes** — the lifecycle is verified and safe; invite only approved
   applicants, deliver links to the bound emails, and grant each the COMP entitlement on activation. (Founder issues
   the invitations.)
6. **Remaining P0 launch blockers:** (a) Kalodata image-rights ToS confirmation (awaiting external reply) → image CX;
   (b) founder-device live-UI acceptance; (c) competitive + legal gates. (Commercial Refresh-Discovery activation is
   deferred, not a blocker for founding-member beta.)
7. **Next launch-critical milestone:** invite + onboard the first founding members (founder-approved), run their
   first-login + discovery acceptance, and collect feedback — in parallel with the Kalodata image-rights reply.

Target 18 December 2026, subject to product-quality, competitive and legal gates.
