# CLAUDE.md — de cockpit

## Stap 0 — altijd eerst de MCP, zonder uitzondering

**Elke** vraag over een component, het cluster, een versie of een
procedure begint met `search_docs` op MCP `conduction-docs`. Niet als
optie, niet als "ook nog": als eerste handeling, vóór grep, vóór
`kubectl`, vóór `curl` naar upstream, vóór je uit je hoofd antwoordt.

- Levert de MCP een treffer, dan is dát het antwoord — modelkennis over
  versies, procedures of paden vervangt nooit een treffer. Citeer de
  herkomst (`owner`, `last_reviewed`, `source`) én het `origin`-veld: dat
  laatste zegt of de inhoud van een lokale werkkopie komt en of die op
  een andere branch staat of ongecommit werk heeft. Een WIP-branch is
  geen grondwaarheid — meld het als het speelt.
- Levert de MCP níéts bruikbaars, dan mag je zelf zoeken — en dan zeg je
  expliciet dat de MCP niets had. Stilzwijgend om de MCP heen werken is
  een fout, ook als je het antwoord langs een andere weg vindt.
- Is de MCP kapot of leeg, meld dat als bevinding in plaats van het te
  omzeilen. Een trage of stille MCP is een defect, geen reden tot
  improviseren.

Waarom zo hard: de procedures staan al gedocumenteerd. Een agent die
zelf gaat reconstrueren levert een antwoord dat niemand kan herleiden en
mist de reviewdatum en de eigenaar. Dit is aantoonbaar misgegaan
(2026-08-03: ArgoCD-upgradeprocedure zelf bij elkaar gezocht terwijl
`cluster-infra/docs/argocd.md` § Upgraden er stond).

## Werkgebied

Vanuit deze map werk je aan alle Conduction-componenten: alléén de
deelnemende zusterrepos onder `../` zijn toegankelijk (de lijst staat
in `.claude/settings.json` en spiegelt `scripts/clone_all.sh` — houd
die twee gelijk). Andere mappen onder `../` vallen buiten het
hub-programma; kom je die nodig, vraag het eerst.

## Router (ná stap 0)

| Wil je… | Ga naar |
|---|---|
| weten hoe een component werkt | MCP `conduction-docs` (search/read, mét herkomst én `origin`) |
| aan een component werken | `../<repo>` — lees éérst `docs/agents.md` dáár (het operatie-cataloog van die component geldt, niet dit bestand) |
| de regels/het programma | `../techbook` (openspec, contract, audit) |
| repos klonen/bijwerken | `./scripts/clone_all.sh` (idempotent, juiste remotes) |
| een werkplek inrichten | `./scripts/onboard.sh` (rapporteert; `--apply` voert uit) |
| idem, met een venster | `./scripts/onboard_gui.py` (vult voor, roept hetzelfde script) |

## Agent-guardrails (gelden hier extra streng: multi-repo-sessies)

- Per component geldt zíjn cataloog: **niet gecatalogiseerd = eerst
  vragen**. Bij twijfel welke repo een wijziging raakt: eerst uitzoeken,
  dan pas bewerken.
- Grondwaarheid: MCP `conduction-docs` boven modelkennis — zie stap 0,
  dat is een harde eerste handeling en geen richtlijn.
- Vóór afronden per geraakte repo: `./scripts/verify.sh` groen; docs mee
  in dezelfde wijziging.
- Push en cluster-mutaties doet een mens — per repo, met de juiste
  remote (de repos verschillen; `clone_all.sh` zet ze goed).
  Nooit `--no-verify`.
