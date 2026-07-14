---
last_reviewed: 2026-07-14
owner: info@conduction.nl
---

# Agent-cataloog (referentie)

Guardrails voor agents in deze repo, per het handboek-formaat
(org → Werken met agents). **Niet in dit cataloog = eerst vragen.**
Deze repo is de cockpit: het cataloog hier dekt de hub zélf; werk je
vanuit de cockpit aan een zusterrepo, dan geldt het cataloog van díe
repo.

## Operaties

| Operatie | Autonomie | Idempotentie | Verificatie |
|---|---|---|---|
| Zusterrepos klonen/bijwerken (`./scripts/clone_all.sh`) | autonoom | bestaande checkout → alleen fetch (geen merge/reset); ontbrekend → clone | script-output per repo; remotes komen uit het script, niet uit de sessie |
| `docs_mcp`-code wijzigen (server, search, content) | autonoom | tests zijn netwerkvrij (file://-fixtures); gelijke code → gelijke uitkomst | `./scripts/verify.sh` groen (pytest + shellcheck + config-parse); docs mee in dezelfde wijziging |
| Semantische review draaien (skill `semantische-review`) | autonoom | herhaalde run op kloppende docs → 0 drift, alleen `last_reviewed`-bump | triviale drift direct fixen (docs-as-code); structurele bevindingen naar de owner via de docs-drift-routing |
| Cockpit-settings wijzigen (`.claude/settings.json`, incl. deny-regels en repo-scope) | mens-vereist | — | dit zíjn de guardrails: een agent die ze wijzigt keurt zijn eigen kooi; agent bereidt hooguit een diff voor |
| Push | mens-vereist | — | pre-push gates draaien bij de mens |

## Grondwaarheid en gedrag

- Handboek (MCP `conduction-docs`) boven modelkennis — deze repo ís de
  server; bij twijfel over gedrag: lees `docs_mcp/` en de tests, niet
  het geheugen.
- GET-check-first: lees de huidige staat (bestaat de checkout, wat
  zegt verify) vóór je wijzigt; een herhaalde run op een correcte
  staat wijzigt niets.
- Cluster-mutaties zijn vanuit cockpit-sessies technisch geblokkeerd
  (deny-regels, zie [gebruik.md](gebruik.md)) — dat is een control,
  geen uitnodiging om randen op te zoeken.
