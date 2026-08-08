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

# Git exporteert deze variabelen naar hooks. Ze lekken door naar pytest en
# vandaar naar de `git`-aanroepen in de tests, die dan een tijdelijke repo
# aanmaken maar op DEZE repo committen — waardoor de tests falen zodra ze via
# een hook draaien in plaats van direct. Losknippen, zodat het niet uitmaakt
# hoe dit script wordt aangeroepen.
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_PREFIX \
      GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES \
      GIT_COMMON_DIR GIT_INTERNAL_GETTEXT_SH_SCHEME 2>/dev/null || true
uv run --with pytest python -m pytest tests/ -q
shellcheck scripts/*.sh
python3 -c "import json; json.load(open('.mcp.json')); json.load(open('.claude/settings.json'))"
echo "verify: OK (tests + lint + config)"
