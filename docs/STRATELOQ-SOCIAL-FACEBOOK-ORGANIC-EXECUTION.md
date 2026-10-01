# STRATELOQ — Facebook Organic Publish Executor (first execution leg)

**Unit:** STRATELOQ-SOCIAL-FACEBOOK-ORGANIC-EXECUTION-001
**Verdict:** `PASS_READY_FOR_CONTROLLED_LIVE_TEST`
**Status:** Internal implementation + validation complete. The connected Page already holds the
required publishing scope, so this unit is **not** blocked on external Facebook permission. No real
Facebook post was created — live publishing remains disabled by design (VALIDATE_ONLY).

This unit implements the first missing execution leg identified by
`STRATELOQ-SOCIAL-PUBLISHING-DISCOVERY` by **extending** the existing Strateloq social publishing
spine. It adds nothing parallel: it reuses the existing preflight, required-scopes contract, secret
vault and connection row, and adds only the attempt/result ledger and the organic executor that were
genuinely absent.

---

## 1. CURRENT STATE VERIFIED

Verified live against Supabase project `nxaunmyihhjixxxljcqt` before writing any code:

- **No organic publish executor existed** — no `fn_social_*organic*execute*` function.
- **No attempt/result ledger existed** — `to_regclass` for `social_publish_attempts` and
  `social_post_results` both returned `NULL`.
- **The existing contracts were present and reused unchanged:** `fn_social_publishing_preflight`,
  `fn_social_publishing_request`, `fn_social_required_scopes`, `fn_social_scope_subset_ok`,
  `fn_social_secret_read`, `social_platform_connections`, `social_publishing_requests`.
- **The live organic Facebook connection is CONNECTED and publish-capable:** connection
  `4650f21e-06c3-4b28-8c99-5e47377e6536`, tenant `5351ad83-5ce8-47b1-aef6-23f64daf415f`, Page
  `1273960209136806` ("Pulse Intelligence"), `granted_scopes` include
  `pages_show_list, pages_read_engagement, pages_manage_posts`, capabilities include
  `PUBLISH_TEXT, PUBLISH_IMAGE`, and a Page token is present in the Vault
  (`social:4650f21e-…:page`). Because the required publishing scope is already granted, the external
  permission gate is satisfied.

## 2. FILES / MIGRATIONS CHANGED

- `supabase/migrations/mig_344_social_facebook_organic_execution.sql` — new migration (applied).
- `docs/STRATELOQ-SOCIAL-FACEBOOK-ORGANIC-EXECUTION.md` — this report.

No existing migration, function, table or contract was renamed or altered. n8n was **not** touched
(see §12) — the Monday-only production intelligence scan schedule is untouched.

## 3. TABLES / CONTRACTS ADDED

**`social_publish_attempts`** (tenant-scoped durable ledger, idempotency-keyed):
`id, tenant_id, actor_user_id, publishing_request_id→social_publishing_requests,
platform, connection_id→social_platform_connections, attempt_no, idempotency_key (UNIQUE),
execution_mode, execution_state, error_class, error_message, started_at, completed_at, created_at`.

**`social_post_results`** (tenant-scoped durable ledger):
`id, tenant_id, actor_user_id, publishing_request_id, publish_attempt_id→social_publish_attempts,
platform, platform_post_id, permalink, published_at, result_state, error_class, error_message,
outbound_payload, created_at`.

- **Neither table has an OAuth/token column.** Tokens are never persisted.
- **RLS enabled, tenant-isolated:** members can `SELECT` only rows where
  `tenant_id = fn__own_tenant()`; there is **no** INSERT/UPDATE/DELETE policy, so all writes are
  default-denied and happen only via the SECURITY DEFINER executor / service_role.
- **Idempotency guard (authoritative):** partial unique index
  `social_post_results_one_published_per_request ON (publishing_request_id) WHERE result_state='PUBLISHED'`
  → at most one PUBLISHED post can ever exist per request, even under a race.

**Executor:** `fn_social_facebook_organic_execute(p_request_id uuid, p_actor uuid DEFAULT NULL,
p_mode text DEFAULT 'VALIDATE_ONLY', p_idempotency_key text DEFAULT NULL)` →
`jsonb`. SECURITY DEFINER, `search_path=''`, EXECUTE granted to `authenticated, service_role` only
(revoked from PUBLIC/anon).

## 4. FACEBOOK EXECUTOR IMPLEMENTED

Step sequence (all reusing existing contracts):

1. Resolve actor — `auth.uid()` wins over `p_actor` so authenticated callers cannot impersonate;
   service-role/n8n callers pass `p_actor`.
2. Resolve the actor's tenant from their `member.application_ref` (same rule as `fn__own_tenant`).
3. Load the `social_publishing_requests` row; reject if missing.
4. **Tenant ownership:** request `tenant_id` must equal the actor's tenant → else
   `CROSS_TENANT_REJECTED`.
5. Structural gates: platform must be `META_FACEBOOK`; `connection_type` must be `ORGANIC`
   (anything else, incl. `ADVERTISING`, → `WRONG_CONNECTION_TYPE`).
6. Content-type gate: `TEXT` or `SINGLE_IMAGE` only → else `UNSUPPORTED_CONTENT_TYPE`.
7. Idempotent replay (explicit key) and **ALREADY_PUBLISHED** short-circuit (returns the existing
   PUBLISHED result instead of republishing).
8. Claim an idempotent attempt (`ON CONFLICT (idempotency_key) DO NOTHING`) before any token read.
9. **Preflight** via `fn_social_publishing_preflight`; require `READY_FOR_MANUAL_PUBLISH`.
10. Resolve the CONNECTED ORGANIC Page connection (same match rule as preflight, capability-checked).
11. **Scope verification** via `fn_social_required_scopes` + `fn_social_scope_subset_ok` (external gate).
12. Resolve the Page token **only** via `fn_social_secret_read(secret_ref)` into a local variable —
    used for nothing, never returned, logged or stored, then nulled.
13. Prepare the real outbound Graph payload (TEXT → `/{page}/feed`; SINGLE_IMAGE → `/{page}/photos`)
    with the credential **deliberately excluded**.
14. Record attempt + result state. **VALIDATE_ONLY/DRY_RUN** writes a non-published `VALIDATED`
    result and stops; any other mode is refused as `LIVE_PUBLISH_NOT_AUTHORIZED` **without sending**.

Content types: **TEXT** and **SINGLE_IMAGE + caption** only. Carousel / video / reels / stories /
multi-image / cross-platform are rejected; the payload builder is a small switch kept extensible.

## 5. SECURITY MODEL

- **Token handling:** the Page token is read solely through the existing SECURITY DEFINER vault read
  (`fn_social_secret_read`, EXECUTE restricted to postgres/service_role), held in a local variable,
  used for nothing in VALIDATE_ONLY, and discarded. It is never returned, logged, or written to
  either ledger table. Proven by test `token_never_in_ledger_or_response`.
- **No token persistence:** neither ledger table has a token column; `outbound_payload` stores
  `credential: OMITTED_RESOLVED_VIA_VAULT_AT_SEND_TIME`.
- **RLS + tenant isolation:** SELECT-own policies keyed to `fn__own_tenant()`; writes definer-only.
- **Least-privilege EXECUTE:** executor granted to `authenticated, service_role`; self-test to
  `postgres, service_role`; both revoked from PUBLIC.
- **Failure classification (safe, no secrets):** `PREFLIGHT_FAILED, NO_CONNECTED_ACCOUNT,
  INSUFFICIENT_SCOPE, ASSET_NOT_READY, APPROVAL_REQUIRED, IDENTITY_SAFETY_FAILED, PLATFORM_REJECTED,
  NETWORK_RETRYABLE, ALREADY_PUBLISHED, INTERNAL_ERROR`, plus the control states
  `CROSS_TENANT_REJECTED, WRONG_CONNECTION_TYPE, UNSUPPORTED_CONTENT_TYPE, LIVE_PUBLISH_NOT_AUTHORIZED,
  BLOCKED_EXTERNAL_FACEBOOK_PUBLISH_PERMISSION`. Only `NETWORK_RETRYABLE` is marked retryable;
  idempotency is authoritative regardless.

## 6. IDEMPOTENCY PROOF

- Durable, DB-backed: unique `idempotency_key` on attempts + partial unique index enforcing at most
  one PUBLISHED result per request.
- `duplicate_execution_idempotent` test: two executes with the same explicit key produce **one**
  attempt and an `idempotent_replay` on the second (no duplicate result).
- `ALREADY_PUBLISHED` short-circuit returns the existing published result instead of republishing.
- Protects against retries, webhook re-delivery, n8n re-runs, restarts, double-click and timeouts.

## 7. TENANT-ISOLATION PROOF

- Tenant resolved from the actor's member row; the request's `tenant_id` must match.
- `cross_tenant_rejected` test: a different tenant's member executing this tenant's request →
  `CROSS_TENANT_REJECTED`, no ledger write.
- Ledger RLS SELECT-own keyed to `fn__own_tenant()`.

## 8. ORGANIC / PAID SEPARATION PROOF

- **Static:** the executor body contains **no** reference to `reserve_spend`, `release_spend`,
  `marketing_spend_authority`, `spend_reservations`, `marketing_campaign_executions`,
  `create_spend_authority`, `adset` or `campaign` (test `no_spend_or_campaign_reference`).
- **Behavioral:** a dry-run creates **zero** `spend_reservations` rows
  (test `no_spend_reservation_created`).
- **Structural:** a `connection_type='ADVERTISING'` request is rejected `WRONG_CONNECTION_TYPE`
  (test `wrong_connection_type_rejected`); an ADVERTISING connection cannot substitute for an organic
  one — the organic request still fails `NO_CONNECTED_ACCOUNT`
  (test `paid_cannot_substitute_for_organic`).
- The Meta Draft Executor and the paid lane are not imported, reused or referenced.

## 9. REAL FACEBOOK CONNECTION / SCOPE RESULT

Run against the **real** connected Page (no post created): the executor resolved connection
`4650f21e-…`, Page `1273960209136806`, verified the granted scopes are a superset of the required
`["pages_show_list","pages_read_engagement","pages_manage_posts"]` (`scope_ok=true`), and resolved
the Page token from the Vault (`token_resolved=true`, `token_exposed=false`). Because the scope is
already granted, the external publish-permission gate is **satisfied** — this unit is not blocked on
Meta permission. (If a connection ever lacked the scope, the executor returns
`BLOCKED_EXTERNAL_FACEBOOK_PUBLISH_PERMISSION` with the missing scopes, where it is approved, and that
internal work is otherwise complete.)

## 10. DRY-RUN RESULT

`VALIDATE_ONLY` ran the full pipeline — preflight → real Page/scope resolution → token resolution →
real outbound Graph payload build → attempt claim/idempotency → recorded a non-published `VALIDATED`
result (`platform_post_id`, `permalink`, `published_at` all NULL) — and **stopped before any Graph
API call**. There is **no live-send code path** in the function and **no HTTP primitive**
(`net.http_*` / `pg_net`) anywhere in its body (tests `no_http_primitive_in_executor`,
`no_live_send_branch`), so a dry-run cannot fall through to a live post. `pg_net` exists in the
project but the executor never calls it.

## 11. TEST RESULTS — `fn_social_facebook_organic_selftest` **15/15** (all rolled back; nothing posted)

| Case | Result |
|---|---|
| no_http_primitive_in_executor | pass |
| no_spend_or_campaign_reference | pass |
| no_live_send_branch | pass |
| owner_single_image_validated (real Page) | pass |
| real_connection_scope_resolution_no_post | pass |
| no_spend_reservation_created | pass |
| token_never_in_ledger_or_response | pass |
| text_path_feed_payload | pass |
| duplicate_execution_idempotent | pass |
| cross_tenant_rejected | pass |
| unapproved_caption_rejected | pass |
| identity_or_launch_unsafe_rejected | pass |
| wrong_connection_type_rejected | pass |
| paid_cannot_substitute_for_organic | pass |
| live_mode_refused_no_send | pass |

Post-run verification: `social_publish_attempts=0`, `social_post_results=0`, `PUBLISHED=0`, and no
test connection persisted — the whole suite ran in rolled-back subtransactions. Security advisors:
**0 ERROR** (4 WARN / 1 INFO baseline, unchanged).

## 12. EXTERNAL BLOCKERS

**None blocking.** The connected Page already grants `pages_manage_posts`, so the external
publish-permission gate is satisfied for the current connection. (For production at scale, Meta App
Review of `pages_manage_posts` may apply to other Pages/tenants; the executor surfaces
`BLOCKED_EXTERNAL_FACEBOOK_PUBLISH_PERMISSION` with the missing scope in that case.)

**n8n:** no workflow was added. The executor is a DB RPC callable manually by the app/service-role,
so no n8n node is genuinely needed to validate it, and adding one risked introducing an automated
publish path. No scheduled/automatic trigger was created and the Monday-only production intelligence
scan schedule is untouched. A minimal **manual-test-only** "Facebook Organic Publish Executor"
workflow (single manual trigger → RPC in VALIDATE_ONLY) can be added later if an orchestration entry
point is wanted; it is not required for this unit.

## 13. GIT COMMIT

Branch `claude/brave-knuth-uxowfg`. See commit referenced in the task summary for
`mig_344_social_facebook_organic_execution.sql` + this doc.

## 14. FINAL VERDICT

**`PASS_READY_FOR_CONTROLLED_LIVE_TEST`** — the organic Facebook publish executor and its durable,
tenant-isolated, idempotent attempt/result ledger are implemented, reuse the existing architecture,
enforce the organic/paid separation, never expose or persist tokens, and pass 15/15 self-tests.
Live posting is disabled (VALIDATE_ONLY) and **no Facebook post was created**. The connected Page
holds the required scope, so the system is ready for a founder-authorized, controlled first live
publication — which remains a separate, explicit authorization per the stop condition.
