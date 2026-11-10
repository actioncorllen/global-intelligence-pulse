#!/usr/bin/env bash
# Controlled unit test for the billing-staging security-gate DECISION logic
# (.github/workflows/billing-staging-security-gate.yml → "Evaluate" step).
#
# It mirrors the workflow's decision tree and asserts the outcome for each branch,
# so the four conditions are verifiable without a GitHub runner:
#   RELEVANT=false                     -> PASS  (not applicable; required check never blocks unrelated PRs)
#   RELEVANT=true, fork PR             -> BLOCK (no secret shared with forks)
#   RELEVANT=true, same-repo, no secret-> BLOCK (never a misleading green)
#   RELEVANT=true, same-repo, secret   -> RUN   (execute the Tier-1 read-only gate)
#
# This file lives OUTSIDE the gate's controlled paths, so a push that only touches it
# also exercises the "not applicable -> PASS" path in real GitHub Actions.
set -euo pipefail

# decide() returns the decision token for the given inputs (same order as the workflow).
decide() { # $1=RELEVANT $2=IS_FORK $3=DB_URL
  local RELEVANT="$1" IS_FORK="$2" DB_URL="${3:-}"
  if [ "$RELEVANT" != "true" ]; then echo "PASS_NOT_APPLICABLE"; return 0; fi
  if [ "$IS_FORK" = "true" ]; then echo "BLOCK_FORK"; return 0; fi
  if [ -z "${DB_URL:-}" ]; then echo "BLOCK_NO_SECRET"; return 0; fi
  echo "RUN_GATE"; return 0
}

fail=0
assert() { # $1=desc $2=expected $3=actual
  if [ "$2" = "$3" ]; then printf 'PASS  %-38s -> %s\n' "$1" "$3"
  else printf 'FAIL  %-38s expected=%s actual=%s\n' "$1" "$2" "$3"; fail=1; fi
}

assert "unrelated change (RELEVANT=false)"        "PASS_NOT_APPLICABLE" "$(decide false false '')"
assert "fork PR touching controlled files"        "BLOCK_FORK"          "$(decide true  true  '')"
assert "same-repo, controlled files, no secret"   "BLOCK_NO_SECRET"     "$(decide true  false '')"
assert "same-repo, controlled files, secret set"  "RUN_GATE"            "$(decide true  false 'postgresql://x')"

if [ "$fail" -ne 0 ]; then echo "GATE LOGIC TEST FAILED"; exit 1; fi
echo "GATE LOGIC TEST PASSED (4/4)"
