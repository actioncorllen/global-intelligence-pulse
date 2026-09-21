# STRATELOQ-TIKTOK-AUTH-REPLACEMENT-014D

**FINAL VERDICT: `TIKTOK_SECURE_AUTH_MECHANISM_BLOCKED`.**

Honest engineering determination: **there is no non-Custom-Auth n8n *credential* mechanism that can
place TWO secrets (`client_key` + `client_secret`) into the *form-urlencoded request body* of the
TikTok token call.** Within n8n's credential model, body injection is a capability of the **Custom Auth
family only** — the exact family 014D instructed me to permanently abandon. Every other mechanism
(`httpBasicAuth`, `httpBearerAuth`, `httpDigestAuth`, `httpHeaderAuth`, `httpQueryAuth`, `oAuth1Api`,
`oAuth2Api`, and every predefined credential type) is a **header/query** injector or emits the wrong
field name (`client_id`, not `client_key`). Under the four hard constraints you set — **not header, not
query, not OAuth2-with-`client_id`, not Custom Auth** — the compliant solution set inside n8n
credentials is **empty**. No secrets were handled, no live TikTok call was made, and **nothing was
changed** (no DB, no workflow, no credential, no code). The deprecated `httpCustomAuth` path is left
present-but-unused as instructed. Below is the full proof and a decision-ready menu of what would
unblock this, with a recommendation, so you can authorise a path in the next unit.

---

## 1. What TikTok's token call actually requires (locked from prior units)
`POST https://open.tiktokapis.com/v2/oauth/token/`
- `Content-Type: application/x-www-form-urlencoded`
- **body** (form-encoded): `client_key=<…>&client_secret=<…>&grant_type=client_credentials`
- Field names are TikTok-specific: **`client_key`** (NOT the OAuth-standard `client_id`) and
  **`client_secret`**.

So a compliant mechanism must (a) securely store two secrets, (b) inject **both** into the **body**,
(c) as **form-urlencoded**, (d) under the field name **`client_key`** (not `client_id`).

## 2. Every n8n auth mechanism, mapped against your constraints (proof of exhaustion)
The HTTP Request node (v4.5) exposes exactly these authentication surfaces (confirmed from the installed
node type definition, `genericAuthType` enum + `predefinedCredentialType`):

| Mechanism | Where it injects | Two secrets? | Meets TikTok body + `client_key`? | Your constraint | Verdict |
|---|---|---|---|---|---|
| `httpBasicAuth` | `Authorization: Basic` **header** | yes (user/pass) | ✗ header, and Basic-encoded | "not header" | **Excluded** |
| `httpBearerAuth` | `Authorization: Bearer` **header** | ✗ (one token) | ✗ header | "not header" | **Excluded** |
| `httpDigestAuth` | `Authorization: Digest` **header** | yes | ✗ header | "not header" | **Excluded** |
| `httpHeaderAuth` | one **header** name/value | ✗ (one) | ✗ header | "Do NOT use Header Auth" | **Excluded** |
| `httpQueryAuth` | one **query** param | ✗ (one) | ✗ query string | "not query" | **Excluded** |
| `oAuth1Api` | OAuth1 signature **header** | n/a | ✗ header, wrong protocol | (OAuth) | **Excluded** |
| `oAuth2Api` (client-credentials) | body/header, **but field name is `client_id`** | yes | ✗ emits `client_id`, not `client_key` | "not OAuth2 unless it sends `client_key`" — n8n hardcodes `client_id` | **Excluded (proven)** |
| **`httpCustomAuth`** | headers / **body** / qs (literal JSON blob) | yes | ✓ body-capable | **explicitly banned (deprecated, failed 014C)** | **Excluded** |
| **`httpTemplatedCustomAuth`** ("Simplified Custom Auth", 2.35.0+) | headers / **body** / qs (template + fields) | yes | ✓ body-capable | **still the "Custom Auth" family** | **Excluded — see §3** |
| `predefinedCredentialType` (e.g. `supabaseApi`) | service-hardcoded header injection | n/a | ✗ no TikTok Commercial Content predefined type exists; predefined types are header injectors | (n/a) | **Excluded** |

**Only the Custom Auth family injects into the body.** That is the crux: n8n deliberately does **not**
let an HTTP Request node reference `{{$credentials.*}}` inside its own body/header parameters (the SDK
expression surface exposes `$json`, `$()`, `$now`, … but **not** `$credentials`). Custom Auth exists
precisely *because* body/multi-value secret injection is otherwise impossible — which is why banning it
removes the only body-injection door.

## 3. Why `httpTemplatedCustomAuth` does not rescue this (and is treated as banned)
`httpTemplatedCustomAuth` is n8n's newer "**Simplified Custom Auth**." It improves the *ergonomics* of
Custom Auth (secrets entered as discrete encrypted fields + a template with `{{marker}}` placeholders,
instead of one literal-secret JSON blob), and it **can** target the body. It is the only n8n-native path
that could technically work. I am **excluding** it for two independent reasons:

1. **It is the Custom Auth family you banned.** n8n surfaces it in the UI as "**Custom Auth**" and it is
   built on a **Custom Auth JSON template**. Your 014D constraint was unambiguous and repeated: *"Do NOT
   attempt Custom Auth again … Under no circumstances return to httpCustomAuth / Custom Auth JSON."*
   Choosing a differently-named-internally but UI-labelled-"Custom Auth", JSON-template mechanism would
   violate the plain instruction. I will not relax your security constraint on my own initiative.
2. **A live TikTok correctness risk even if you allowed it.** Open n8n defect
   [#21898](https://github.com/n8n-io/n8n/issues/21898): Custom-Auth body injection is serialised as a
   **JSON** body *even when the node's Content-Type is `application/x-www-form-urlencoded`*. TikTok's
   token endpoint strictly requires form-encoding, so this path carries a real risk of a fresh
   `invalid_request`/`invalid_client` failure — trading one credential defect for another.

## 4. What would unblock this — decision menu for the next unit (you choose)
None of these can proceed without your explicit authorisation, because each either relaxes a constraint
you set or requires you to enter the two secrets yourself (I never handle secret values).

- **Option A — Accept `httpTemplatedCustomAuth` (relax the Custom-Auth ban to the *templated* variant only).**
  The single n8n-native path. You would create a new "Custom Auth" (Simplified) credential in the n8n UI
  storing `client_key` + `client_secret` as encrypted fields with a body template, and attach it to the
  Token node. *Pros:* stays entirely in n8n, no new infra. *Cons:* it is the Custom-Auth family you asked
  to leave; and defect #21898 may still send a JSON body to a form-only endpoint. **Not recommended
  unless you explicitly overrule the ban.**

- **Option B (RECOMMENDED) — Mint the token in a Supabase Edge Function; n8n never sees the secrets.**
  Store `client_key`/`client_secret` in **Supabase Vault** (server-side, service-role only — *not*
  exposed to the browser, anon, RLS, or the Lovable client). A small edge function performs the exact
  form-urlencoded `client_credentials` POST to TikTok and returns only a short-lived Bearer token. n8n
  calls that function with the **existing** Supabase service-role credential (unchanged) and uses the
  returned token for the Ad Query. *Pros:* completely outside the Custom Auth family; secrets never live
  in n8n or the workflow JSON; form-encoding is done in our own code so #21898 cannot bite; token TTL
  handled server-side. *Cons:* the secrets live in Supabase Vault — if your "no Supabase exposure"
  constraint was meant to forbid Vault storage too (not just browser/anon exposure), say so and I'll drop
  this. **This is the most secure and most robust path and I recommend it, pending your read of
  "Supabase exposure."**

- **Option C — Tiny dedicated token-minting proxy (e.g. a single Cloudflare Worker / minimal function)
  holding the two secrets as platform secrets**, called by n8n. Same shape as B but off-Supabase.
  *Pros:* off both the Custom Auth family and Supabase. *Cons:* introduces a new piece of infrastructure
  to run and secure.

I recommend **Option B**. If instead you want to keep everything inside n8n and are willing to accept
the *templated* Custom Auth specifically (distinct from the failed blob), say so and I'll implement
Option A and hand you placeholder-only UI steps for entering the two secrets.

## 5. Structured RETURN
1. **Question asked:** "Best NON-Custom-Auth n8n mechanism to store two secrets and inject them into the
   TikTok form-urlencoded token body." **Answer:** none exists — body injection in n8n credentials is a
   Custom-Auth-family capability only; all non-Custom-Auth mechanisms are header/query or emit
   `client_id`. Proven by exhaustion in §2.
2. **Mechanism chosen / implemented:** none (constraint set is empty within n8n credentials). No
   `httpTemplatedCustomAuth` configured — it is Custom-Auth family (§3) and I will not relax your ban
   unilaterally.
3. **Secrets:** never requested, printed, inspected, logged, or handled. No live TikTok call performed.
4. **Changes made:** **none** — no migration, no SQL, no n8n workflow edit, no credential create/edit/
   delete, no Lovable change. The only writes this unit are this report + its git commit.
5. **Deprecated path:** the `httpCustomAuth` credential `Pulse TikTok Commercial Content`
   (`id9au7UBaSXn3dq0`) and its binding on the Token node remain **present but unused / do-not-run**, as
   instructed ("do not delete yet"). I did not rename or alter it.
6. **State (unchanged by construction — zero mutations this unit):** TikTok provider remains
   `SOURCE_UNSUPPORTED` / `APPROVED_CREDENTIAL_SETUP_REQUIRED`; the SOCIAL_VIDEO live attempt remains
   `BLOCKED_EXTERNAL_ACCESS`; 0 SOCIAL_VIDEO / TIKTOK commerce signals; GB nightlight 68.2 / DE 73.2
   unchanged; 15 founder products, no duplicates; business country GB; no synthetic evidence; scores,
   decisions and discovery provenance untouched.
7. **Commit hash / push:** see delivery message.

**STOP.** No Custom Auth (of any variant), no header/query auth, no OAuth2, no secrets handled, no live
TikTok call, no Lovable/publish/Stripe. Verdict `TIKTOK_SECURE_AUTH_MECHANISM_BLOCKED`: the requested
non-Custom-Auth n8n-credential mechanism does not exist; unblocking requires a decision from you among
Options A / B (recommended) / C above.
