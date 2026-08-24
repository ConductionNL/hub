---
last_reviewed: 2026-08-24
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
| Werkplek inrichten (`./scripts/onboard.sh`) | mens-vereist | zonder `--apply` wijzigt hij niets; met `--apply` kloont hij niets opnieuw, voegt geen dubbele deny-regels toe en herschrijft het profielblok niet — kubeconfigs wél verse, die verlopen na 24u | `--self-test` (9 fixtures, netwerkvrij) en daarna een run zonder `--apply`: die laat per stap zien wat er zou gebeuren. Mens-vereist omdat hij `~/.claude/settings.json`, `~/.kube/config` en desgevraagd je shellprofiel raakt |
| Werkplek inrichten via de GUI (`./scripts/onboard_gui.py`) | mens-vereist | geen eigen staat; alles gaat via `onboard.sh` | `--self-test` (7 fixtures) toetst dat de voorgevulde waarden niet uiteenlopen met de defaults van het script en dat 'Controleren' nooit `--apply` meestuurt. Vraagt `python3-tkinter`; zonder dat verwijst hij naar het script |
| `docs_mcp`-code wijzigen (server, search, content) | autonoom | tests zijn netwerkvrij (file://-fixtures) en isoleren de git-omgeving (`c.clean_git_env()`, zie hieronder); gelijke code → gelijke uitkomst | `./scripts/verify.sh` groen (pytest + shellcheck + config-parse); docs mee in dezelfde wijziging |
| Semantische review draaien (skill `semantische-review`) | autonoom | herhaalde run op kloppende docs → 0 drift, alleen `last_reviewed`-bump | triviale drift direct fixen (docs-as-code); structurele bevindingen naar de owner via de docs-drift-routing |
| Cockpit-settings wijzigen (`.claude/settings.json`, incl. deny-regels en repo-scope) | mens-vereist | — | dit zíjn de guardrails: een agent die ze wijzigt keurt zijn eigen kooi; agent bereidt hooguit een diff voor |
| Repo-hooks wijzigen (`.claude/hooks/`) | mens-vereist | tekstueel | zelfde reden als de settings, en technisch afgedwongen: `claude-pre-tool-use.sh` weigert elke schrijfactie op een pad met `.claude/hooks/`. Agent levert script + patch aan, de mens installeert |
| `CLAUDE.md` wijzigen (de sessie-instructies zélf, incl. stap 0) | mens-vereist, voorstel-eerst | tekstueel | zelfde reden als de settings: dit is de kooi, niet het werk. Alleen op expliciete opdracht van een mens, en die opdracht hoort in de CHANGELOG-regel te staan (zo ging 2026-08-03: stap 0 op verzoek van Mark) |
| Certificaat-swap Epe (`./scripts/swap_epe_cert.sh`) | mens-vereist | secret al aanwezig / al gemerged / al gepusht → melding, geen fout | **opgebruikt**: eenmalige reparatie van 2026-08-11, kopieert alleen uit ns `epe` en kan geen verse bundel plaatsen. Verlengen gaat via `certswap`, zie `openwoo-app-config/docs/custom-domain-cert.md`. Stap 5 is een harde toets op het cluster (exitcode 1 bij afwijking); stap 2 en 4 muteren het cluster en vragen bevestiging |
| Push | mens-vereist | — | pre-push gates draaien bij de mens |

## Gates

Naast `docs-contract` en `docs-claims` draait sinds 2026-08-10 de
diff-gate `docs-touched`: raakt een push `docs_mcp/` of `scripts/`,
dan hoort er documentatie mee te wijzigen. De padregels met hun reden
staan in `.docs-touched.yaml` in de repo-root. De gate staat op
`mode: warn` — hij rapporteert en blokkeert nog niet. Configformaat,
vrijstelling (`Docs-not-needed`-trailer) en verificatie: techbook
`docs/docs-touched.md`.

## Grondwaarheid en gedrag

- Handboek (MCP `conduction-docs`) boven modelkennis — deze repo ís de
  server; bij twijfel over gedrag: lees `docs_mcp/` en de tests, niet
  het geheugen.
- Stap 0 staat sinds 2026-08-21 niet alleen in `CLAUDE.md` maar wordt bij
  elke prompt ingespoten door `.claude/hooks/mcp-first.sh`
  (`UserPromptSubmit`). Reden: proza kan wegzakken in een lange sessie —
  dat gebeurde in een sessie van een collega terwijl de MCP wél
  beschikbaar was. De hook reist mee met de clone; wie hem uit
  `.claude/settings.json` haalt, haalt de handhaving weg en houdt alleen
  de intentie over.
- GET-check-first: lees de huidige staat (bestaat de checkout, wat
  zegt verify) vóór je wijzigt; een herhaalde run op een correcte
  staat wijzigt niets.
- Cluster-mutaties zijn vanuit cockpit-sessies technisch geblokkeerd
  (deny-regels, zie [gebruik.md](gebruik.md)) — dat is een control,
  geen uitnodiging om randen op te zoeken.

## Git-aanroepen: veeg de omgeving schoon

`cwd=` bepaalt **niet** op welke repo git werkt zodra `GIT_DIR` in de
omgeving staat: dan wint `GIT_DIR`. Git zet die variabele zelf voor élke
hook.

Er zijn twee lagen bescherming, en je hebt ze allebei nodig:

1. `scripts/verify.sh` unset de omleidende `GIT_*`-variabelen vóór pytest.
   Dat dekt de gebruikelijke weg — de pre-push hook.
2. Elke git-aanroep in `docs_mcp/` én in de tests loopt via
   `content.clean_git_env()`. Dat dekt wat laag 1 níét ziet: de MCP-server
   kloont zelf repos, en niet elke pytest-run gaat via `verify.sh`.

Laat je laag 2 weg, dan is de isolatie afhankelijk van wie je aanroept.
Aangetoond op 2026-08-10 in een kloon van deze repo, met pytest direct en
alleen `GIT_DIR` gezet: de suite muteerde de werkboom van de repo waar die
variabele naar wees (`docs/index.md` gewijzigd, `docs/other.md` verwijderd).
Zonder `GIT_DIR` gebeurt er niets, en daarom valt het bij los draaien nooit op.

Elke git-aanroep — in `docs_mcp/` én in de tests — loopt daarom via
`content.clean_git_env()`. `TestHookOmgevingIsolatie` bewaakt dat met een
lokvogel-repo: `GIT_DIR` wijst ernaar, de suite doet zijn werk, en daarna
moet die repo onaangeroerd zijn. Schrijf je elders een test die
git-repo's aanmaakt, neem dan hetzelfde patroon over.
