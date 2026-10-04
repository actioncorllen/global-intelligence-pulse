# STRATELOQ — First Controlled LIVE Facebook Organic Publication

**Unit:** STRATELOQ-SOCIAL-FACEBOOK-CONTROLLED-LIVE-PUBLISH-001
**Verdict:** `PASS_CONTROLLED_FACEBOOK_LIVE_PUBLISH`

One founder-approved organic post was published to the real Pulse Intelligence Facebook Page,
verified on-platform, and proven idempotent (a deliberate re-run created no second post). Zero
advertising spend, zero scheduling, zero autonomous publishing. Built on mig_344/mig_345; no scope
expansion.

## 1. PRE-PUBLISH VERIFICATION
- mig_344 + mig_345 applied; executor, ledger, grant table, send helpers present.
- Connection `4650f21e-06c3-4b28-8c99-5e47377e6536` CONNECTED, `pages_manage_posts` granted,
  PUBLISH_TEXT/IMAGE capable, token in vault; organic/paid separation intact.
- Request `ae88ea07-c9e1-478c-bdef-07c1a77e1bb0`: TEXT, caption approved, destination Page
  `1273960209136806`, preflight `READY_FOR_MANUAL_PUBLISH`.
- VALIDATE_ONLY dry-run (pre-send): `scope_ok=true`, token resolved (not exposed), no post.
- Founder approved the exact caption, then gave explicit `PUBLISH`.

## 2. EXACT CONTENT PUBLISHED
```
Turn market signals into business opportunities — and opportunities into action.

Pulse is a SaaS platform that helps businesses discover opportunities, analyse market and competitor signals, identify what’s worth acting on, and move from insight to execution.

From opportunity intelligence and product research to content, campaigns and commerce — Pulse brings the decision and action workflow together in one place.

Discover. Decide. Act.

#SaaS #BusinessIntelligence #BusinessAutomation #MarketIntelligence #Ecommerce
```
(Current Pulse branding; presented as an existing SaaS platform. No Strateloq reference.)

## 3. TARGET FACEBOOK PAGE
Pulse Intelligence — Page ID `1273960209136806` (verified `from.id` matches the connection).

## 4. PUBLISHING REQUEST ID
`ae88ea07-c9e1-478c-bdef-07c1a77e1bb0`

## 5. PUBLISH ATTEMPT ID
`6869a6ed-5618-458f-9da3-b0adb588fb6c` (result row `e33c4727-b85f-43ee-b7aa-2d3eac2229b1`)

## 6. FACEBOOK POST ID
`1273960209136806_122119918455470301`

## 7. FACEBOOK PERMALINK
`https://www.facebook.com/122119918485470301/posts/122119918455470301`
(stored permalink: `https://www.facebook.com/1273960209136806_122119918455470301`)

## 8. PLATFORM VERIFICATION RESULT
Graph API GET on the post id returned HTTP 200: `from.name="Pulse Intelligence"`,
`from.id=1273960209136806` (`matches_connection_page=true`), `message` equals the approved caption
byte-for-byte, `created_time=2026-10-04T22:19:58+0000`. HTTP success alone was not relied on —
content, Page and published state were all confirmed.

## 9. IDEMPOTENCY REPLAY RESULT
Re-executing the same request in LIVE mode returned `ALREADY_PUBLISHED`,
`idempotent_replay=true`, `live_send_performed=false`, and the existing result — **no second
Graph call**.

## 10. DUPLICATE COUNT
PUBLISHED results for the request: **1**. Distinct platform_post_ids: **1**. PUBLISHED attempts:
**1**. No duplicate public post.

## 11. PAID-LANE SAFETY RESULT
No campaign, ad set, ad, or spend reservation created; `marketing_spend_authority` unchanged; no
campaign state change. Today: 0 spend_reservations, 0 authority rows, 0 campaign_executions created
(last spend_reservation 2026-09-08). Advertising spend attributable to this operation: **$0**. The
executor statically references no paid-lane contract.

## 12. TOKEN / SECRET SAFETY RESULT
The Page token was resolved only via the vault (`fn_social_secret_read`) inside the SECURITY DEFINER
executor, passed in-memory to the restricted send helper, and nulled. The token string does **not**
appear anywhere in `social_publish_attempts` or `social_post_results` for this request (substring
search position = 0); the stored `outbound_payload.credential` is
`OMITTED_RESOLVED_VIA_VAULT_AT_SEND_TIME`. Never returned, logged, or persisted.

## 13. REGRESSION TEST RESULTS
`fn_social_facebook_organic_selftest` **14/14** post-publish (executor has no raw HTTP primitive;
send helper restricted to postgres/service_role; LIVE requires grant; gates precede send; tenant
isolation; cross-tenant rejection; identity/launch-safety; wrong-connection-type; idempotency;
token non-exposure; no spend/campaign reference; zero spend reservations; VALIDATE_ONLY default).
`fn_social_connection_selftest` 5/5 (foundation unregressed by the additive TEXT gate). Security
advisors: 0 ERROR (4 WARN / 1 INFO baseline).

## 14. AUTONOMY STATE AFTER TEST
VALIDATE_ONLY remains the executor default; no automatic transition to LIVE. The single-use live
grant is consumed (`consumed_at` set); **0 open grants remain**. The publishing request is now
`EXECUTION_DISABLED`. No AUTO_PUBLISH flag, no scheduled/recurring publishing, no n8n production
trigger was created. The Monday-only intelligence scan schedule is untouched. The system is capable
of controlled publishing but cannot autonomously publish further posts.

## 15. FILES / MIGRATIONS CHANGED
- `supabase/migrations/mig_345_social_facebook_controlled_live_publish.sql` (applied; committed).
- `docs/STRATELOQ-SOCIAL-FACEBOOK-CONTROLLED-LIVE-PUBLISH.md` (this report).
- Runtime records (not code): one live grant (consumed), one PUBLISHED attempt+result, validation
  records. No other contract changed; `http` extension enabled in the `extensions` schema.

## 16. GIT COMMIT
Branch `claude/brave-knuth-uxowfg`: `b50d7fb` (mig_345 capability) + the delivery-doc commit
referenced alongside this file.

## 17. FINAL VERDICT
**`PASS_CONTROLLED_FACEBOOK_LIVE_PUBLISH`** — one real organic post published to the correct Page,
verified on-platform, idempotent on replay, with zero spend, no token exposure, no duplicate, and no
residual publishing authority. STOP condition honoured: nothing else published; no progression to
scheduling, Instagram, LinkedIn or TikTok.
