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

---

# Operational Completion — Entitlement provisioning & delivery (2026-11-10, P0)

Follow-up to the accepted backend lifecycle above. Goal: make onboarding **operationally
reliable** before inviting the first five. No security test rebuilt; the application/invitation
system is unchanged. **No invitation sent, no real applicant emailed, no account activated, no
billing/signup/paid refresh enabled. One backend function deployed (inert until a founder
invokes it for a specific activated member); no payment provider is ever called.**

## P1 — Entitlement provisioning: **RESOLVED** (was the Stage-4/#9 PARTIAL)
**Problem:** `accept_invitation` provisions member + discovery_state but not the
`ecommerce_monthly` entitlement. The two live members were comped by a hand-written backfill
(`granted_by '012A internal COMP backfill'`); there was **no reusable, verified grant path** —
the operational gap.

**Fix (deployed): `fn_grant_founding_member_entitlement(p_auth_user_id, p_granted_by, p_notes)`**
— migration `mig_345_founding_member_comp_grant.sql` (DB: `founding_member_comp_entitlement_grant`).
A controlled **founder-admin grant step** (not auto-on-activation — see *Design choice* below).
Properties, each verified (10/10 rolled-back cases):

| Requirement | How it is met | Test |
|---|---|---|
| 1. Only founder-approved, **activated** members qualify | requires a provisioned `member` (which only exists after a founder-issued invitation was accepted) that is `active` **and** has exactly one `discovery_state` | R0/R1/D1 reject |
| 2. Correct user **and** tenant | resolves `member_id` from `auth_user_id` and stamps it on the row | G1 |
| 3. Idempotent | one row per `auth_user_id` (`UNIQUE`); re-run = `already_granted`, no second row | I1 |
| 4. Failed/incomplete onboarding cannot create access | no member / no workspace / disabled → `rejected`, **no write** | R0/R1/D1 |
| 5. No self-grant | `EXECUTE` to `service_role` + `postgres` only; **revoked from `authenticated`/`anon`/`PUBLIC`** (mirrors `issue_invitation`/`accept_invitation`) | S1 (ACL) |
| 6. No paid subscription / payment-provider call | writes a `COMP` row only; never sets `provider*`; response carries `no_payment_provider_call:true` | G1 row |
| 7. Existing legitimate entitlements preserved | a pre-existing `PROVIDER` (paid) sub is never overwritten (guarded both pre-check and in the `ON CONFLICT ... WHERE`) → `preserved` | P1 |

Post-deploy live checks: grants are `service_role`+`postgres` only; calling it for a real
non-member returns `rejected/no_member` with **no write** (still 2 entitlements) — confirming it
is inert and safe.

**Design choice — controlled grant, not auto-on-activation.** Auto-comping every member who
activates any invitation would hand a paid-tier entitlement out as a side-effect of activation —
the commercial/policy decision the founder reserved in Stage 4. The directive permits preserving
"a controlled founder-admin grant step" when automation carries that risk; this does exactly
that, while replacing the unreliable hand-written backfill with a verified, idempotent, secure
one-call grant.

### Founder operation (run in the Supabase SQL editor — privileged/service-role)
```sql
-- 1) find the activated member by their email
select m.auth_user_id, m.id as member_id, m.account_status
from public.member m
where lower(btrim(m.email)) = lower(btrim('MEMBER_EMAIL_HERE'));

-- 2) grant the COMP entitlement (idempotent; safe to re-run)
select public.fn_grant_founding_member_entitlement(
  'AUTH_USER_ID_HERE'::uuid,
  'founder onboarding',      -- granted_by label (stored on the row)
  'founding member'          -- optional note
);
-- expect {"status":"ok","outcome":"granted","active":true,"no_payment_provider_call":true,...}
-- a member with no workspace yet -> {"status":"rejected","reason":"workspace_not_provisioned"}
```

## P2 — Invitation delivery: manual founder delivery (made explicit)
**Verified:** the `issue-invitation` edge makes **no outbound call** (`fetch` count 0), wires **no
email provider** (no Resend/SMTP/SendGrid/etc.), and **never logs raw tokens** (no `console.*`).
It returns the one-time link for the founder to deliver.

**Authorised email infrastructure that exists:** the founder's n8n holds an **SMTP account** and
several **Gmail OAuth2** accounts — a non-paid transport *does* exist. **It is deliberately not
wired to invitation delivery**, because routing a one-time invitation token through an n8n
workflow would persist that token in n8n execution history (a token exposure outside the
founder's control), and transactional deliverability/domain-auth for strateloq.com is not set up
there. For five hand-picked founders, **manual founder delivery is the safe, recommended
procedure** and keeps delivery under founder control:

1. Founder runs `issue-invitation` (founder/admin auth) → copies the returned one-time link.
2. Founder sends the link **from their own mailbox to the exact bound email only**. No third
   parties; no reuse; links expire in 14 days.
3. The applicant signs up at strateloq.com with the **same email** (Supabase Auth sends the
   signup-confirmation email), confirms, then opens the invite link.

Automated invitation email remains an **optional, founder-approved future enhancement** (would
require a no-log transactional path + strateloq.com domain auth); not a launch blocker.

## P3 — Full non-chargeable acceptance (incl. entitlement): **17/17 PASS** (rolled back)
One forward trace chaining the **real** functions, synthetic fixtures, transaction rolled back:

application submitted (no account) → **founder approval required** (issuance rejected pre-approval)
→ invitation issued → correct email binding (validate) → activation → member + discovery_state →
workspace correctly withholds pre-grant (`ENTITLEMENT_REQUIRED`) → **entitlement granted** (new
step, active, no payment call) → `WORKSPACE_PREPARING` → **`READY`** once discovery ready →
duplicate invitation blocked → re-accept = `already_provisioned` (no duplicate member) → duplicate
grant idempotent → cross-tenant isolation (entitlement scoped to the user/tenant; another user
gets no workspace) → failure recovery (bogus/invalid tokens fail safe; member & entitlement counts
unchanged). Post-run: nothing persisted — 0 test members, entitlements still 2, the 6 real pending
applications untouched.

## P4 — First-five readiness
**Founder-operated workflow (no automatic selection or invitation):**
1. Review the queue — `founding_applications WHERE status='new'` (6 real pending) via
   `list-issuable-applications`. Verify work email + fit. **Choose up to five.**
2. Approve + invite — create the applicant's unowned `business_profiles` (approval marker), run
   `issue-invitation` (founder/admin) → deliver the one-time link to that exact email (P2).
3. Activate — applicant signs up at strateloq.com with the same email, confirms, opens the link →
   `accept-invitation` provisions member + discovery_state.
4. **Grant entitlement** — run `fn_grant_founding_member_entitlement` for that member (P1 snippet).
   Confirm `active:true`.
5. First-login + Product Discovery acceptance + feedback + per-account security checks (as in the
   Stage 5 runbook above).

**Do not select, invite, or grant for any real applicant without founder approval of the specific
person.** Paid Refresh Discovery stays disabled.

### Minimum founder-device checklist (live, signed in at strateloq.com)
Per onboarded member, on their first login:
- [ ] Sign-in succeeds; lands in the ecommerce workspace (not the entitlement/paywall gate).
- [ ] Dashboard loads; country selector present.
- [ ] Product Discovery shows image-gated products; open one product drawer (correct identity + image).
- [ ] Add one product to My Store; My Store shows it (page UNPUBLISHED).
- [ ] (optional) Create Free Store; My Campaigns nav present.
- [ ] Refresh Discovery shows the "not activated / pricing not set" state (paid refresh stays off — correct).
- [ ] Member sees only their own tenant data (no other members' data/admin functions).

## Operational completion — verdict
Entitlement provisioning is now **reliable and secure** (deployed grant function, 10/10 + 17/17
rolled-back PASS). Invitation delivery is **explicit manual founder delivery** (safe for five;
automation optional/approved-later). The complete onboarding path including the entitlement step
is **PASS (backend, rolled-back)**. The only remaining founder actions are the per-member founder
operations above and the founder-device live-UI checklist — plus the standing external/launch
gates (Kalodata image-rights reply; competitive + legal). **First five can be invited and
onboarded reliably** once the founder approves the specific applicants.

---

# First Founding-Member Pilot Preparation (2026-11-10, P0)

Prepare a safe, founder-controlled onboarding pilot for **ONE** real approved founding member.
Nothing applicant-specific is mutated here: **no approval, no business profile, no invitation, no
entitlement grant, no contact** was executed. mig_345 and the 17/17 acceptance are accepted and
not re-run. All queries below are read-only.

## P1 — Founder application review (read-only queue view)
Existing admin surface: the `list-issuable-applications` edge (founder/admin-gated) and the
`founding_applications` table (`status='new'`). Minimal review view used (shows only what the
founder needs to choose, plus issuance-eligibility signals):

```sql
select
  row_number() over (order by created_at) as n,
  id as application_id,
  first_name || ' ' || last_name as applicant,
  work_email, company, country, industry, role, company_size,
  primary_goal, use_case, current_workflow, source, status, created_at,
  (select count(*) from public.business_profiles bp where bp.application_id = fa.id) as has_business_profile,
  (select count(*) from public.member m where m.application_ref = fa.id)            as has_member,
  (select count(*) from public.invitation i where i.application_ref = fa.id)        as invitations
from public.founding_applications fa
where status = 'new'
order by created_at;
```

**Current queue = 6 pending, but only one is a clean genuine pilot candidate.** Classification
(by `application_id`; applicant PII shown to the founder in-session, not committed here):

| # | application_id | Classification | Issuance-eligible? |
|---|---|---|---|
| 1 | `4919ce8d-…` | internal **verification test** (has 2 prior invitations) | no (test artifact) |
| 2 | `b40f8bb6-…` | internal **"final test"** verification | no (test artifact) |
| 3 | `a4906ed3-…` | **genuine applicant** (UK marketing agency); profile present, no member, 0 invitations | **yes — clean pilot candidate** |
| 4 | `95bb5658-…` | real-looking, **already has a provisioned member** (5 invitations) | no — already onboarded; issuance would reject |
| 5 | `f760ad56-…` | automated **QA** form test | no (test artifact) |
| 6 | `83427880-…` | automated **QA** form test | no (test artifact) |

Recommendation for the founder: run the pilot on the single genuine, not-yet-onboarded candidate
(#3). **The founder selects; nothing is approved or invited automatically.** (A queue cleanup —
marking the 4 test artifacts and the already-onboarded row to a non-`new` status — is an optional,
founder-approved follow-up, not done here.)

## P2 — One-member onboarding procedure (exact, founder-authorised at each mutation)
Reuses the existing workflow and `fn_grant_founding_member_entitlement` (mig_345). Run only after
the founder picks the individual.

1. **Founder approval → business profile.** Create the applicant's **unowned** business profile
   (approval marker; `user_id` NULL) for the chosen `application_id`. (If the chosen application
   already has one — as #3 does — this step is already satisfied; confirm it is unowned.)
2. **Issue secure invitation** — call the `issue-invitation` edge (founder/admin-gated; the
   caller's identity is verified server-side against a founder allowlist):
   ```
   POST /functions/v1/issue-invitation
   Authorization: Bearer <founder session JWT>
   { "application_ref": "<application_id>", "bound_email": "<applicant work email>" }
   ```
   The edge generates the token + SHA-256 hash itself, persists via `issue_invitation(...)`, and
   returns the one-time token **exactly once** (never logged). 14-day expiry, bound to that email.
3. **Founder delivers** the invite link **from the founder's own mailbox to that exact bound
   email only** (manual delivery — see P4; no automation, no third parties, no reuse).
4. **Customer accepts** — applicant signs up at strateloq.com with the **same** email, confirms
   it (Supabase Auth sends the confirmation), and opens the invite link → `accept-invitation`
   provisions member + discovery_state.
5. **COMP entitlement granted** — founder runs (Supabase SQL editor / service role):
   ```sql
   select m.auth_user_id from public.member m
   where lower(btrim(m.email)) = lower(btrim('<applicant email>'));

   select public.fn_grant_founding_member_entitlement(
     '<auth_user_id>'::uuid, 'founder onboarding', 'pilot founding member');
   -- expect {"status":"ok","outcome":"granted","active":true,"no_payment_provider_call":true,...}
   ```
6. **Workspace READY** — once discovery completes (`discovery_state.analysis_status='ready'`),
   `fn_workspace_access` returns `READY`. Entitlement-active is immediate after step 5.

Each of steps 1, 2 and 5 is a **founder-authorised mutation**; none runs without the founder
choosing the individual.

## P3 — Pilot member acceptance checklist (first customer)
1. Open the invitation link on **strateloq.com**.
2. Register or sign in using the **authorised (bound) email**.
3. Confirm account activation (email confirmed; invite accepted → member provisioned).
4. After the COMP grant, reach the **ecommerce workspace** (not the entitlement/paywall gate).
5. Select a **country**.
6. Browse products showing **genuine permitted display images** (image-gated; image-pending
   products are **not** shown).
7. Open a **product detail** drawer (correct product identity + image).
8. **Add Product to My Store.**
9. Confirm the product **persists** in My Store (page UNPUBLISHED; exact identity).
10. Verify **mobile usability** and capture feedback.

Guardrails during the pilot: **paid Refresh Discovery stays inactive** (shows the "not
activated / pricing not set" state); **Product Asset Lock is not bypassed**; image-pending
products are never displayed.

## P4 — Operational safety (confirmed, read-only)
All pilot invariants verified to currently hold:

| Invariant | Evidence (today) |
|---|---|
| Invitation-only registration | `member` RLS on, **0 INSERT policies** (members created only by SECURITY DEFINER `accept_invitation`); no public self-provision |
| Email-bound, single-use links | `invitation` carries `bound_email` + `token_hash` (UNIQUE) + `status`/`consumed_at` lifecycle; `accept_invitation` rejects on email mismatch / consumed / revoked / expired |
| Privileged entitlement grants | `account_entitlement` RLS on with **0 policies** (deny-all); `fn_grant_founding_member_entitlement` EXECUTE = `service_role`/`postgres` only |
| No billing | **0 active prices, 0 active allowances**; **0 `PROVIDER` subscriptions** |
| No paid API usage | **0 active `provider_call_budget`** → paid Refresh Discovery fail-closed/inactive |
| Tenant/country isolation | member is `auth_user_id`-scoped; workspace market-scoped (verified in the 17/17 acceptance) |
| No unauthorised storefront publishing | Product Asset Lock + image gate enforced; My Store pages created UNPUBLISHED |

Manual invitation delivery is the pilot method; **no email automation that would expose
invitation tokens is introduced** (an authorized n8n SMTP/Gmail transport exists but is
deliberately not wired — it would persist one-time tokens in execution logs).

## Pilot readiness — verdict
Founder review is ready (queue surfaced with eligibility + test-artifact flags). The one-member
procedure is prepared and reuses only verified components. The acceptance checklist is defined.
Safety invariants are confirmed. **No genuine operational blocker** to running a one-member pilot
— it needs only the founder's selection of the individual and the per-member founder-authorised
mutations above, plus the founder-device live-UI walk-through. Paid Refresh Discovery and the
Kalodata image-rights item remain out of scope for the pilot (image-pending products stay hidden;
the pilot relies on the already-permitted FastMoss reference-image products).
