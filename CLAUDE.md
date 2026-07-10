# CLAUDE.md — de cockpit

Vanuit deze map werk je aan alle Conduction-componenten: alléén de
deelnemende zusterrepos onder `../` zijn toegankelijk (de lijst staat
in `.claude/settings.json` en spiegelt `scripts/clone_all.sh` — houd
die twee gelijk). Andere mappen onder `../` vallen buiten het
hub-programma; kom je die nodig, vraag het eerst. Begin bij het
handboek (MCP `conduction-docs`) voor elke component-vraag.

## Router

| Wil je… | Ga naar |
|---|---|
| weten hoe een component werkt | MCP `conduction-docs` (search/read, mét herkomst) |
| aan een component werken | `../<repo>` — lees éérst `docs/agents.md` dáár (het operatie-cataloog van die component geldt, niet dit bestand) |
| de regels/het programma | `../techbook` (openspec, contract, audit) |
| repos klonen/bijwerken | `./scripts/clone_all.sh` (idempotent, juiste remotes) |

## Agent-guardrails (gelden hier extra streng: multi-repo-sessies)

- Per component geldt zíjn cataloog: **niet gecatalogiseerd = eerst
  vragen**. Bij twijfel welke repo een wijziging raakt: eerst uitzoeken,
  dan pas bewerken.
- Grondwaarheid: MCP `conduction-docs` boven modelkennis.
- Vóór afronden per geraakte repo: `./scripts/verify.sh` groen; docs mee
  in dezelfde wijziging.
- Push en cluster-mutaties doet een mens — per repo, met de juiste
  remote (de repos verschillen; `clone_all.sh` zet ze goed).
  Nooit `--no-verify`.
