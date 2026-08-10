# Changelog

## 2026-08-10 — docs-touched-gate erbij, techbook-pin op v0.2.0

De hookset kende geen gate op §7 van de conventies: documentatie wijzigt
in dezelfde PR als de code die zij beschrijft. `docs-contract` en
`docs-claims` kijken naar de hele boom en nooit naar wat je pusht, dus
code veranderen zonder de docs bij te werken kwam er ongehinderd langs.
`docs-touched` is de diff-gate die dat wél ziet.

- `.pre-commit-config.yaml`: techbook-pin van `edf269ee…` naar `v0.2.0`
  en `- id: docs-touched` toegevoegd. Die twee horen in één wijziging:
  de hook bestáát niet in `edf269ee…`, dus los toevoegen faalt, en een
  pin op een niet-bestaande rev laat pre-commit al bij het uitchecken
  van de techbook-repo stuklopen — dat zou óók `docs-contract`,
  `docs-claims` en `verify` meenemen. Meteen de eerste tag in plaats van
  een kale sha; daar stappen we vanaf.
- `.docs-touched.yaml` (nieuw): `docs_mcp/**` omdat dat de MCP-server is
  die `docs/gebruik.md` beschrijft (tools, bronkeuze, env-defaults), en
  `scripts/**` omdat `clone_all.sh` de repo-scope bepaalt en
  `verify.sh` de gate zelf is. `CLAUDE.md`, `.claude/**`, `tests/**`,
  `.github/**` en lockfiles staan in `ignore`: de guardrails beschrijven
  zichzelf en zijn mens-vereist.
- `docs/agents.md`: sectie Gates met de verwijzing; `last_reviewed` bij.

De gate staat op **`mode: warn`** — hij rapporteert volledig en geeft
exit 0. Eerst een periode meekijken of de padregels op deze repo geen
ruis opleveren; pas daarna naar `enforce`. Een gate die eeuwig alleen
waarschuwt wordt genegeerd, dus de omzetting hoort na een rustige maand
te gebeuren en niet later.

## 2026-08-10 — git-omgeving schoonvegen vóór elke aanroep

`cwd=` bepaalt niet op welke repo git werkt zodra `GIT_DIR` gezet is; dan
wint `GIT_DIR`. Git zet die variabele in de omgeving van elke hook, en
`scripts/verify.sh` is als pre-push hook gedeclareerd — de testsuite draait
dus routinematig in precies die omgeving.

Aangetoond in een kloon van deze repo: met alleen `GIT_DIR` gezet muteerde de
suite de werkboom van de repo waar die variabele naar wees (`docs/index.md`
gewijzigd, `docs/other.md` verwijderd). Zonder `GIT_DIR` gebeurt er niets,
waardoor het bij los draaien nooit opvalt. De aanleiding was een incident in
techbook, waar dezelfde fout 24 fixture-commits in de gepushte branch zette.

- `docs_mcp/content.py`: `REPO_ENV_VARS` + `clean_git_env()`; `_git_env()`
  gebruikt dat. Dit raakt niet alleen de tests — de MCP-server kloont zelf
  repos en kon onder een gelekte `GIT_DIR` de verkeerde repo bewerken.
- `tests/test_docs_mcp.py`: alle git-aanroepen via één `git()`-helper met
  die schone omgeving, plus `TestHookOmgevingIsolatie` met een lokvogel-repo
  die na de hele suite onaangeroerd moet zijn.
- `docs/agents.md`: de claim "gelijke code → gelijke uitkomst" gold niet
  zolang de uitkomst van `GIT_DIR` afhing; aangevuld met het waarom.

## 2026-08-08 — docs-gate ook server-side

De hooks in `.pre-commit-config.yaml` draaiden alleen bij wie
`pre-commit install` had gedaan. Een PR van iemand zonder hooks passeerde
ongecontroleerd, terwijl die hooks juist de afspraak zijn dat docs meebewegen
met de code.

`.github/workflows/ci.yml` draait dezelfde hooks op elke PR en elke push naar
main. Geen tweede lijst met checks — dat is een tweede lijst die gaat afwijken.

Proef voor de andere infra-repos: van de elf hebben er negen de
docs-contract-hook, maar draaiden er twee hem in CI (cluster-infra,
openwoo-app-config). Branch protection staat nergens aan, dus ook een groene
check is nog niet verplicht; dat is een aparte stap.

Daarbij: de hookbron stond nog op `codeberg.org/Conduction/techbook`. Sinds de
migratie is dat `github.com/ConductionNL/techbook`, zelfde rev — in CI zou de
oude host anders een externe afhankelijkheid op een verlaten platform zijn.

De proef vond meteen iets: `scripts/verify.sh` faalde *via* de hook maar
slaagde direct. Git exporteert `GIT_DIR` c.s. naar hooks; die lekten door naar
pytest en vandaar naar de `git`-aanroepen in de tests, die dan op déze repo
committen in plaats van op hun tijdelijke repo. De hub-verify-hook heeft als
pre-push dus nooit gewerkt. Het script knipt die variabelen nu los, zodat het
niet uitmaakt hoe je hem aanroept.

Wat dit **niet** afdwingt: of de prozatekst nog klopt met de code. Hooks
controleren structuur en uitvoerbare blokken; de rest is de periodieke
semantische review.


## 2026-08-03 — publiek en grondwaarheid ontkoppeld (interne componentenlijst)

### Aanleiding

De publieke handbook-site publiceerde de docs van `cluster-config`, een
private repo: clusternaam, provider, tenant-inventaris. Die moest uit de
publieke trust root (`repos:` in `handbook/mkdocs.yml`).

Probleem: `docs_mcp/content.py` gebruikte diezelfde lijst als **enige**
bron voor welke componenten bestaan. Een repo uit de site halen maakte hem
dus ook onzichtbaar voor agents. Dat was al gebeurd bij `KeyCloak` — die
stond nergens meer in `list_components`, terwijl niemand dat had besloten.
Eén knop deed twee dingen.

### Toegevoegd

- `docs_mcp/internal_components.yaml` — componenten die de MCP wél ziet en
  het portaal niet. Nu `cluster-config` en `KeyCloak`. Zelfde vorm als
  `mkdocs.yml`, zodat één parser volstaat. Pad env-tunable via
  `DOCS_MCP_INTERNAL_COMPONENTS`; leeg zetten schakelt de aanvulling uit,
  dan ziet de MCP precies wat het portaal publiceert. Ontbrekend bestand is
  geen fout.
- `Component.internal` en `Page.internal`; `parse_internal_list()`,
  `load_internal_list()` en `_merge()`. Bij een dubbele naam wint de
  publieke lijst — die publiceert, dus mag niet als intern gelden.
  Namen case-insensitief gededupliceerd (`React-base` vs `react-base`).
- **`publication: public|internal`** in elk MCP-antwoord
  (`read_page`, `search_docs`) en per component in `list_components`.
  Zonder dat veld lopen publiek en grondwaarheid stil uit elkaar, en dat
  is precies het soort onzichtbaar verschil dat deze sessie opruimde: wie
  een `internal`-pagina naar buiten citeert, geeft een `source`-URL die de
  ontvanger niet kan openen.

### Verificatie

10 nieuwe tests (31 totaal, was 21), waaronder één die de meegeleverde
`internal_components.yaml` tegen de werkelijkheid houdt in plaats van tegen
een fixture. Gecontroleerd tegen de aangepaste `handbook/mkdocs.yml`:
publiek 7 componenten, MCP 9 — `cluster-config` en `KeyCloak` als
`INTERN`.

## 2026-08-03 — MCP koud bruikbaar + herkomst eerlijk; "MCP eerst" hard gemaakt

Aanleiding: bij een ArgoCD-vraag liep de eerste `search_docs` over de 120s
tool-limiet van een agent-call en moest naar de achtergrond, waarna de
sessie de upgradeprocedure zelf reconstrueerde terwijl
`cluster-infra/docs/argocd.md` § Upgraden al bestond. Twee defecten eronder,
niet één gedragsfout.

- `docs_mcp/content.py`: **lokale werkkopie is nu de bron.** Staat een
  component onder `DOCS_MCP_LOCAL_ROOT` (default `..`), dan leest de MCP die
  map; netwerk-clone blijft fallback voor wat lokaal ontbreekt. Namen worden
  case-insensitief gematcht (`React-base` ↔ `react-base`). Koud antwoorden:
  ~0,14s tegen eerder >120s over 9 seriële clones.
- `docs_mcp/content.py` + `server.py`: **`origin` in de herkomst.** Een
  werkkopie kan op een feature-branch staan of ongecommit werk hebben; dan is
  de inhoud géén weergave van `source`. `origin` benoemt de gebruikte bron,
  de branch, een waarschuwing als die van de importlijst afwijkt, en of er
  ongecommitte wijzigingen zijn. Zonder dit zou de snelheidswinst een
  WIP-branch tot grondwaarheid promoveren.
- `docs_mcp/content.py`: **host-agnostisch gemaakt** als voorwaarde voor de
  migratie naar GitHub — `_page_url()` kiest `/blob/` (GitHub) of
  `/src/branch/` (Forgejo/Codeberg), en de credential-host komt uit de
  clone-URL i.p.v. hardgecodeerd `codeberg.org`. `HANDBOOK_MKDOCS_URL` naar
  `raw.githubusercontent.com`. Zonder deze drie zou het omzetten van de
  importlijst stille 404's en een dood token opleveren.
- `docs_mcp/content.py`: limieten env-tunable i.p.v. hardgecodeerd —
  `DOCS_MCP_GIT_TIMEOUT` (default 20s, bewust onder de tool-limiet) en
  `DOCS_MCP_IMPORT_LIST_TIMEOUT` (30s). `env_int()` valt terug op de default
  bij onzin-waarden. Een `TimeoutExpired` markeert de component nu als
  onbeschikbaar i.p.v. de call te laten klappen.
- `CLAUDE.md`: "MCP eerst" van router-tabelrij naar **stap 0** — een harde
  eerste handeling met expliciete regels voor wat je doet als de MCP niets
  of niets bruikbaars levert, en de eis het `origin`-veld te citeren.
- `scripts/clone_all.sh` (commit `cbe31c1`, los gecommit): kloonde nog van
  `codeberg.org` terwijl de header al GitHub claimde — header en code spraken elkaar tegen, en `CLAUDE.md` beloofde
  "de juiste remotes". Nu `FORGE` (default `github.com/ConductionNL`, env-tunable
  met Codeberg als fallback) plus een expliciete `REMOTE_NAME`-map voor de twee
  repos waar de lokale mapnaam afwijkt van de forge-naam (`react-base` →
  `React-base`, `talos` → `Talos`). Dit is sinds deze wijziging load-bearing:
  de werkkopieën die dit script maakt zíjn de bron van de MCP.
- `README.md` + `docs/gebruik.md`: de drie nieuwe variabelen, de sectie over
  lokale bron vs. herkomst, en Codeberg-links naar GitHub.
- `docs/agents.md`: rij voor "`CLAUDE.md` wijzigen" — mens-vereist,
  voorstel-eerst, om dezelfde reden als de cockpit-settings (een agent die de
  sessie-instructies bijstelt keurt zijn eigen kooi). De wijziging van vandaag
  is op expliciet verzoek van Mark gedaan; dat hoort vastgelegd, anders is dit
  een stil precedent.
- `tests/test_docs_mcp.py`: 21 tests groen (was 12). Nieuw: lokale bron
  zonder netwerk, casing-match, herkomst meldt branch + ongecommit werk,
  fallback naar clone, `/blob/` vs `/src/branch/`, env-tunable limieten. Een
  autouse-fixture isoleert de suite van de fleet-root, zodat tests
  netwerk- én fleet-vrij blijven.

## 2026-07-14 — operatiecataloog toegevoegd (add-component-skills fase 0)

- `docs/agents.md`: de hub had als cockpit-repo zelf geen cataloog —
  per de escalatieregel was hier alles mens-vereist. Nu gecatalogiseerd:
  clone_all/docs_mcp/semantische-review autonoom (met verify-gates),
  cockpit-settings en push mens-vereist.

## 2026-07-13 — eigenaarschap → info@conduction.nl (review WP8)
- Alle `owner:`-front-matter en CODEOWNERS omgezet van `mark` naar
  `info@conduction.nl` (opvolging na 2026-08-31). Voorbereid op branch
  `chore/wp8-ownership`; review, merge en push door een mens.

## 2026-07-10 (middag) — review-bevindingen verwerkt (symlink-guard, WP3, WP7)

Nagedragen op 2026-07-13; de commits zelf zijn van 2026-07-10.

- `docs_mcp/content.py`: symlink-guard in `pages()` — zelfde padbegrenzing
  als `read_page`, met test (review-bevinding; commit 374f7b8).
- `.claude/settings.json` + `docs/gebruik.md`: cockpit deny-rules —
  cluster-mutaties technisch geblokkeerd i.p.v. alleen conventie
  (review WP3; commit 5b9f946); chirurgisch, `kubectl kustomize`/`get`
  blijven werken voor de verify-gates.
- `.pre-commit-config.yaml`: secret-scanning gates fleet-wide
  (gitleaks + detect-private-key, review WP7; commit 4df1b38).

## 2026-07-10 — cockpit-scope beperkt tot deelnemende repos

- `scripts/clone_all.sh`: verouderde entry `docs-mcp` verwijderd (die
  repo heet inmiddels `hub` — dit is deze repo zelf) en `React-base`
  rechtgetrokken naar `react-base`, zodat het script niet naast de
  bestaande checkout een tweede map kloont.
- `.claude/settings.json`: `additionalDirectories` van heel `..`
  versmald tot de tien deelnemende zusterrepos (zelfde lijst als
  `clone_all.sh`). Niet-deelnemende mappen onder `../` zijn vanuit de
  cockpit niet langer toegankelijk.
- `CLAUDE.md`: scope-tekst bijgewerkt; lijsten in settings en
  clone_all.sh horen gelijk te blijven.

## 2026-07-08 — initiële implementatie (openspec change add-docs-mcp)

- MCP-server (mcp==1.28.1, pyyaml gepind, uv): list_components,
  search_docs, read_page — read-only, stdio-only.
- Bron van waarheid: de multirepo-importlijst live uit handbook
  mkdocs.yml; shallow clones met max-age-verversing (default 1u).
- Beveiliging conform spec: padbegrenzing (traversal getest),
  token-hygiëne via 0600 credential-file (lek-test), geen netwerkpoort.
- 12 unit tests (netwerkvrij, file://-fixtures); livetest tegen de 7
  publieke componenten geslaagd (zoek + read met herkomst).
