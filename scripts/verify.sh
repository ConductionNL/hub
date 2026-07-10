#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# role: tool
#
# scripts/verify.sh — snelle functionele verificatie (pre-push gate).
#
# Draait de unit tests (netwerkvrij, file://-fixtures). Dry-run only.
#
# Writes: read-only
# Idempotent: yes
# Requires: uv, git
#
# Usage:
#   ./scripts/verify.sh

set -euo pipefail
cd "$(dirname "$0")/.."
uv run --with pytest python -m pytest tests/ -q
shellcheck scripts/*.sh
python3 -c "import json; json.load(open('.mcp.json')); json.load(open('.claude/settings.json'))"
echo "verify: OK (tests + lint + config)"
