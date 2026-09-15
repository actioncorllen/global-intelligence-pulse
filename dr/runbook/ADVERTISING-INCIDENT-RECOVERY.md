# STRATELOQ DR — ADVERTISING INCIDENT RECOVERY

Dedicated recovery path for an advertising incident (runaway spend, compromised Meta credential, unexpected
activation). **Fail closed. AI confidence never authorizes spend.** Reuses existing contracts — do not rebuild.

## Contracts reused (verified present)
- `fn_pause_all_advertising(p_actor, p_tenant, p_platform)` — pause all advertising (all platforms or one).
- `fn_revoke_spend_authority(p_actor, p_authority_id, p_reason)` — revoke authority → blocks further activation
  and spend-increasing actions.
- `fn_reserve_spend` / `fn_release_spend` / `spend_reservations` — bounded reservation ledger.
- `fn_authority_audit` + `marketing_authority_audit` — immutable audit trail.
- `marketing_spend_authority` — bounded scope (authorized_total, max_daily/campaign/product_test, allowed
  markets/actions, start/end, spent, remaining, status). Current authorities: INACTIVE/REVOKED only, mode=MANUAL.

## Incident sequence
1. **DETECT** — anomaly in `campaign_performance_snapshots` (spend), a Meta alert, or a credential leak.
2. **PAUSE ALL ADVERTISING** — `SELECT fn_pause_all_advertising(<actor>, <tenant>, NULL);` (NULL = every platform).
3. **REVOKE / CONTAIN AUTHORITY** — `SELECT fn_revoke_spend_authority(<actor>, <authority_id>, 'incident');`
   for every active authority. Confirm `status='REVOKED'`, `remaining` frozen.
4. **PRESERVE EVIDENCE** — snapshot `marketing_spend_authority`, `spend_reservations`, `marketing_authority_audit`,
   `campaign_performance_snapshots`, `marketing_campaign_executions` (logical backup); do not delete rows.
5. **ROTATE COMPROMISED CREDENTIALS** — if the Meta system-user token (or any key) is implicated, rotate per
   SECRETS-RECOVERY.md and update every configured location; invalidate old token in Meta.
6. **RESTORE / RECONCILE** — restore app state from the last good logical backup into an isolated target if DB
   corruption is involved; reconcile Meta object states (campaign/adset/ad) against `marketing_campaign_executions`.
7. **VERIFY (all must hold before reopening):**
   - campaign states expected (paused where intended); no unexpected ACTIVE campaign.
   - spend authority states expected (INACTIVE/REVOKED unless a new bounded authority was deliberately created).
   - remaining budget correct; no negative/over-spend beyond authority.
   - campaign fingerprints (`cb_approved_fingerprint`) match the approved version (no silent edit).
   - **recovered advertising state FAILS CLOSED** — nothing auto-activates.
8. **FOUNDER/OPERATOR APPROVAL** — explicit human approval required before any reopening.
9. **REOPEN SAFELY** — only via the normal path: approved campaign + a fresh bounded Spend Authority +
   explicit `fn_request_activation`. Never auto-reopen.

## Standing rules
- The existing **paused Meta proof campaign must never be touched** by recovery automation.
- No recovery step may activate advertising, authorize spend, or raise an authorization.
- Any recovered/imported campaign defaults to REVIEW_AND_MANUAL_LAUNCH and requires Spend Authority to launch.
