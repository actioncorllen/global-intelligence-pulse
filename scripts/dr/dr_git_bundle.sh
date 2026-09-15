#!/usr/bin/env bash
# Independent, provider-agnostic full-repo backup: a single portable git bundle
# containing ALL branches and tags. Restore with: git clone strateloq-<date>.bundle repo
# €0. No history rewrite, no force push, no branch deletion.
set -euo pipefail
OUT="${1:-strateloq-$(date -u +%Y%m%dT%H%M%SZ).bundle}"
git bundle create "$OUT" --all --tags
git bundle verify "$OUT"
echo "Wrote $OUT ($(du -h "$OUT" | cut -f1)). Store this OFF this machine (encrypted offsite)."
