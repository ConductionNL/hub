#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# role: entrypoint
#
# .claude/hooks/mcp-first.sh — injecteert stap 0 (MCP eerst) bij elke prompt.
#
# CLAUDE.md draagt de regel al, maar als proza: een agent kan hem laten
# zakken in een lange sessie, en dat gebeurde 2026-08-21 in een sessie van
# een collega. Deze hook zet dezelfde regel bij elke prompt opnieuw in
# context, zodat de regel niet leunt op wat het model onthoudt. Hij reist
# mee met de clone en werkt dus ook voor wie de README nooit opende.
#
# Bewust triviaal: één heredoc, geen netwerk, geen state, geen jq. Dit
# script draait op de machine van iedereen die deze repo kloont, dus het
# moet in één blik te auditeren zijn.
#
# Stdout van een UserPromptSubmit-hook gaat de context in. Kort houden:
# hij vuurt bij elke prompt en elke regel kost tokens.
#
# Writes: read-only
# Idempotent: yes (zelfde uitvoer bij elke aanroep)
# Requires: bash; wordt aangeroepen door Claude Code, niet met de hand
#
# Usage:
#   ./.claude/hooks/mcp-first.sh                 # print de injectie
#   echo '{}' | ./.claude/hooks/mcp-first.sh     # zoals de hook hem krijgt
#   ./.claude/hooks/mcp-first.sh | wc -c         # contextkosten meten

set -euo pipefail

cat <<'EOF'
Stap 0 (hub): begin met `search_docs` op MCP `conduction-docs` — vóór grep,
vóór kubectl, vóór modelkennis. Een treffer is het antwoord; citeer owner,
last_reviewed, source en origin. Geen treffer of een stille MCP: zeg dat
expliciet, dat is een bevinding en geen vrijbrief om te improviseren.
EOF
