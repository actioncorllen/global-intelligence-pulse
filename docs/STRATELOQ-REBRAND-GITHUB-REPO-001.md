# STRATELOQ-REBRAND-GITHUB-REPO-001

**VERDICT: `COMPLETED — RENAME EXECUTED & VERIFIED (2026-11-12)`.** The source/documentation and public-domain
rebrand from *Global Intelligence Pulse / Global Intelligence Actions* to **Strateloq Technologies** is, in
this repository, **complete**. The founder renamed the GitHub repository
`actioncorllen/global-intelligence-pulse` → **`actioncorllen/strateloq-technologies`**; history, branches, PRs
and the protected integration branch `claude/pulse-crash-recovery-b6ngey` were verified intact, and the single
documented GitHub path in `dr/runbook/DR-INVENTORY.md` was updated to match (§4.4 item 1). No production
Supabase / Stripe / DNS / DR configuration was changed; no DR status was altered (DR **not** marked
RESTORE-READY); no secrets exposed; no security rule weakened. €0 spent.

Date: 2026-11-12 · Branch: `claude/funny-cori-gpsgwq` · Canonical site: <https://www.strateloq.com>

---

## 1. Scope and method

Independent inspection of the repository and the live systems it documents (GitHub metadata, Supabase
projects, Lovable workspaces, the `.github` workflow, DR runbooks/scripts, and the authoritative launch
tracker). This repository is the **operations / infrastructure / DR / security companion repo** — `docs/`,
`supabase/` (migrations + Edge Functions), `dr/`, `scripts/`, one `.github` workflow. It contains **no
React/TS application frontend** (no `package.json`, `src/`, `index.html`, README, badges, or marketing copy);
those public-branding surfaces live in the **Lovable-connected app**, not here, and the tracker records them
as already migrated to `www.strateloq.com` (LIVE VERIFIED 2026-11-12).

## 2. What is already Strateloq (verified, no action required)

| Surface | State | Evidence |
|---|---|---|
| Source/docs brand tokens | `Strateloq` present in 186 files; commit prefixes `STRATELOQ-###` | `git grep -i strateloq` |
| Public domain / website | Canonical `www.strateloq.com`; `strateloq.com`→www; legacy apex & `www.globalintelligenceactions.com`→www (302, 1 hop) | Tracker *Build Evidence & Handoff*, 2026-11-12 rows |
| Supabase — production | Project `nxaunmyihhjixxxljcqt` **renamed to "Strateloq Technologies"**, ACTIVE_HEALTHY, eu-central-1 | `Supabase.list_projects` |
| Supabase — staging | `strateloq-billing-staging` (`nlfkwrjmhxbubtlwepwx`), ACTIVE_HEALTHY | `Supabase.list_projects` |
| Supabase — DR restore | `strateloq-dr-restore` (`zdeedmuocbbkuwuovlbz`), INACTIVE, eu-west-1 | `Supabase.list_projects` |
| CI security gate | `.github/workflows/billing-staging-security-gate.yml` targets `strateloq-billing-staging`; references repo via `github.*` context, **not** a hardcoded name | file inspection |
| DR git backup | `scripts/dr/dr_git_bundle.sh` produces a local `strateloq-<date>.bundle` from the working tree — **no hardcoded clone URL / repo name** | file inspection |

## 3. Residual legacy strings — classification (PRESERVE vs. UPDATE-ON-RENAME)

A full sweep for `Global Intelligence Pulse`, `Global Intelligence Actions`, `global-intelligence-pulse`,
`global-intelligence-actions`, `globalintelligenceactions.com` returned **9 lines total**. Each is classified
below. **Blindly replacing any PRESERVE item would corrupt DR accuracy, Meta CAPI attribution, or an
immutable historical record — exactly what the brief warns against.**

| Location | String | Classification | Reason |
|---|---|---|---|
| `docs/STRATELOQ-DR-FULL-RESTORE-DRILL-003.md:19` | "Global Intelligence Pulse" | **PRESERVE** | Sealed, dated DR drill record (verdict `PARTIAL_PASS`). Name was accurate at capture; production is keyed by the **immutable ref** `nxaunmyihhjixxxljcqt`. Live runbooks already use the ref, so no operator hazard. |
| `docs/STRATELOQ-DR-OFFSITE-AND-DRILL-002.md:36` | "Global Intelligence Pulse" | **PRESERVE** | Same — sealed `-002` drill snapshot. |
| `dr/manifests/BACKUP-ARTIFACT-INDEX.md:10` | "Global Intelligence Pulse" | **PRESERVE** | Byte-fidelity backup integrity record `-004`; keyed by ref. |
| `dr/runbook/DR-INVENTORY.md:9` | `actioncorllen/global-intelligence-pulse` | **UPDATE-ON-RENAME** | Documents the live GitHub path. **Correct until the repo is renamed.** Change *only after* a successful rename (see §4.4). |
| `supabase/functions/meta-capi-adapter/index.ts:286` | `https://globalintelligenceactions.com/` | **PRESERVE** | Live **Meta Conversions API** `event_source_url` for the Meta-**verified** domain. Changing it would break CAPI event attribution. |
| `docs/PULSE-ECOM-P13-META-CAPI-CONNECTION-001.md:48`, `…-CONVERSION-TRACKING-001.md:24` | `globalintelligenceactions.com` | **PRESERVE** | Document the Meta-verified domain + pixel `954179950185340`. Integration contract. |
| `docs/STRATELOQ-ECOM-PAID-ENTITLEMENT-FOUNDATION-012A.md:75`; `supabase/migrations/mig_239_paid_entitlement_foundation.sql:197,209` | `support@globalintelligenceactions.com` | **PRESERVE** | A real `auth.users` email of an internal demo/support account, and an **immutable applied migration** (`mig_239`). Migration identifiers and API/data contracts are never rewritten. |

Additionally, ~50 `PULSE-ECOM-*` document IDs and the "Pulse" pipeline/status token (e.g. "normalized Pulse
status") are **internal historical identifiers**, not public product branding → **PRESERVE**.

**Net: no safe, necessary source edit remains in this repository prior to the rename.** The sole
source-level dependency is the single documented GitHub path in `dr/runbook/DR-INVENTORY.md`, which is a
*post-rename* follow-up (§4.4).

## 4. GitHub repository rename — EXECUTED & verified (2026-11-12)

> **Status: DONE.** Founder renamed the repo in GitHub Settings. Post-rename follow-up §4.4 item 1 applied in
> this PR; Lovable (ID-bound) and the `billing-staging security gate` verified under the new name. Sections
> 4.1–4.5 below are retained as the executed plan / rollback record.

### 4.1 Target and availability
- **Old:** `https://github.com/actioncorllen/global-intelligence-pulse` (public)
- **New (recommended):** `https://github.com/actioncorllen/strateloq-technologies`
- **Availability:** *Appears available* — account `actioncorllen` has **1 public repo** (this one) and no repo
  matching "strateloq" was returned by the accessible-repo listing. Confirm in GitHub before renaming (a
  private repo could still collide). A new repo was **not** created to test (forbidden by brief).

### 4.2 Why this cannot be auto-executed here
The GitHub tool surface available to this unit exposes **no repository-settings / rename operation**, and
creating a replacement repo is forbidden (it would discard history, PRs, releases, protections and
settings). The rename must be performed by the founder (**Settings → General → Repository name → Rename**) or
by an authorized `PATCH /repos/{owner}/{repo}` call. This is also the brief's required **approval gate**.

### 4.3 Exact effects of a GitHub rename (preserved vs. redirected vs. manual)
**Preserved automatically** (GitHub keeps all of this through a rename): full Git history, all commits, tags,
releases, issues, **pull requests (#1, #2 and their merge history)**, **branch protections** (the protected
`claude/pulse-crash-recovery-b6ngey` integration branch and its required `rls-catalog-gate` check),
collaborator permissions, webhooks, deploy keys, repository secrets, environments, Actions workflows and run
history, stars/watchers.

**Redirected automatically:** GitHub installs a permanent redirect from the **old** URL to the new one for
web, Git (`git fetch`/`push` over the old remote), and API. Existing local clones keep working. The redirect
breaks **only** if a *new* repository is later created under the old name `global-intelligence-pulse` — so do
not recreate it.

**GitHub App / integrations:** the Claude GitHub App and Lovable's GitHub connection bind to the repository
**by numeric ID, not by name**, so they survive the rename. Verify sync afterwards regardless (§4.4).

### 4.4 Post-rename follow-up checklist (apply only AFTER a successful rename)
1. `dr/runbook/DR-INVENTORY.md` line 9 → change `actioncorllen/global-intelligence-pulse` to
   `actioncorllen/strateloq-technologies` (the only in-repo doc dependency). *(Deliberately excluded from the
   pre-rename PR so the repo never documents a path that does not yet resolve.)*
2. Founder's local working copies: `git remote set-url origin https://github.com/actioncorllen/strateloq-technologies.git` (optional — the redirect keeps the old URL working).
3. Lovable: confirm the project still syncs to the renamed repo (editor → GitHub → push/pull a trivial change or check the connection panel).
4. Any external deploy that pins the repo by name (e.g. a Hostinger Git deployment source, if used) → repoint to the new name.
5. Re-run the `billing-staging security gate` workflow once to confirm green under the new name.

### 4.5 Rollback
Renaming is **non-destructive and immediately reversible**: rename back to `global-intelligence-pulse`
(Settings → General), which restores the original URL and installs the reverse redirect. Revert follow-up #1
with `git revert`. No history, PRs, protections or secrets are affected either way.

## 5. Operational compatibility verification (Task 3)

- **Lovable — connected.** Two owner workspaces: `Strateoq Technologies` *(note: the workspace name is missing
  an "l" — "Strate**o**q" — flagged to founder; not auto-renamed)* and the legacy `Global Intelligence Pulse`.
  GitHub binding is by repo ID → survives rename.
- **Supabase — intact.** All three projects already Strateloq-named; `strateloq-billing-staging` ACTIVE; the
  security gate and RLS remediation untouched.
- **Stripe — unchanged.** Live-charging controls referenced across 40 files were **not modified**;
  `stripe-card-setup` return origin already canonicalised to `www.strateloq.com` (v14, per tracker);
  `STRIPE_LIVE_ALLOWED=false` and webhook/pilot allowlist preserved.
- **Domain + legacy redirects — LIVE.** `www.strateloq.com` canonical; `globalintelligenceactions.com` (apex
  + www) 302→www, path/query preserved, email DNS continuity intact (tracker 2026-11-12). **Preserved.**
- **Disaster recovery — not disturbed; status unchanged.** No executable DR script hardcodes the repo name.
  The sibling branch `claude/pulse-crash-recovery-b6ngey` (protected trunk) was **not** modified; DR remains at
  its existing `PARTIAL_PASS` posture. **DR was not marked RESTORE-READY** (no real restore drill was run by
  this unit).
- **Isolation / Product Asset Lock / founding-member restrictions — intact by construction.** No DB, RLS,
  Edge Function or policy code was changed, so tenant/country isolation, Product Asset Lock and founding-member
  access enforcement are unaffected.

## 6. Explicit non-actions (and why)
- Did **not** rename the production GitHub repository (gated on founder approval; no tool).
- Did **not** merge any PR or push to the protected branch.
- Did **not** edit sealed DR drill records or any PRESERVE-classified string.
- Did **not** change `mig_239` or any migration identifier / API / data contract.
- Did **not** alter DR status, schedules, encrypted archives, GPG keys or Drive destinations.
- Did **not** touch Stripe charging controls, security rules, or the security gate.

---

*This document is an evidence/decision record. The repository rename itself is the only outstanding
rebranding action and is held at the founder approval gate above.*
