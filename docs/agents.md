---
last_reviewed: 2026-08-03
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
| `docs_mcp`-code wijzigen (server, search, content) | autonoom | tests zijn netwerkvrij (file://-fixtures) en isoleren de git-omgeving (`c.clean_git_env()`, zie hieronder); gelijke code → gelijke uitkomst | `./scripts/verify.sh` groen (pytest + shellcheck + config-parse); docs mee in dezelfde wijziging |
| Semantische review draaien (skill `semantische-review`) | autonoom | herhaalde run op kloppende docs → 0 drift, alleen `last_reviewed`-bump | triviale drift direct fixen (docs-as-code); structurele bevindingen naar de owner via de docs-drift-routing |
| Cockpit-settings wijzigen (`.claude/settings.json`, incl. deny-regels en repo-scope) | mens-vereist | — | dit zíjn de guardrails: een agent die ze wijzigt keurt zijn eigen kooi; agent bereidt hooguit een diff voor |
| `CLAUDE.md` wijzigen (de sessie-instructies zélf, incl. stap 0) | mens-vereist, voorstel-eerst | tekstueel | zelfde reden als de settings: dit is de kooi, niet het werk. Alleen op expliciete opdracht van een mens, en die opdracht hoort in de CHANGELOG-regel te staan (zo ging 2026-08-03: stap 0 op verzoek van Mark) |
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

## Git-aanroepen: veeg de omgeving schoon

`cwd=` bepaalt **niet** op welke repo git werkt zodra `GIT_DIR` in de
omgeving staat: dan wint `GIT_DIR`. Git zet die variabele zelf voor élke
hook, en `scripts/verify.sh` is als pre-push hook gedeclareerd — dus de
testsuite draait routinematig in precies die omgeving.

Aangetoond op 2026-08-10 in een kloon van deze repo: met alleen `GIT_DIR`
gezet muteerde de suite de werkboom van de repo waar die variabele naar
wees (`docs/index.md` gewijzigd, `docs/other.md` verwijderd). Zonder
`GIT_DIR` gebeurt er niets, en daarom valt het bij los draaien nooit op.

Elke git-aanroep — in `docs_mcp/` én in de tests — loopt daarom via
`content.clean_git_env()`. `TestHookOmgevingIsolatie` bewaakt dat met een
lokvogel-repo: `GIT_DIR` wijst ernaar, de suite doet zijn werk, en daarna
moet die repo onaangeroerd zijn. Schrijf je elders een test die
git-repo's aanmaakt, neem dan hetzelfde patroon over.
