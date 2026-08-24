# Changelog

## 2026-08-21 — stap 0 wordt ingespoten door een repo-hook

Op verzoek van Mark. Aanleiding: in een sessie van een collega greep de agent
niet als eerste naar MCP `conduction-docs`, terwijl de server bij hem wél
beschikbaar was. De oorzaak was dus niet de opzet maar de handhaving —
`CLAUDE.md` draagt stap 0 als proza, en proza kan wegzakken in een lange
sessie of bij een andere agent.

Toegevoegd: `.claude/hooks/mcp-first.sh`, aangeroepen als
`UserPromptSubmit`-hook via `$CLAUDE_PROJECT_DIR` in `.claude/settings.json`.
Het script zet stap 0 (302 bytes: `search_docs` eerst, herkomst én `origin`
citeren, stille MCP is een bevinding) bij elke prompt opnieuw in context. Het
reist mee met de clone, dus het werkt ook voor wie de README nooit opende — de
reden om dit als hook te doen en niet als README-sectie.

Bewust triviaal gehouden: één heredoc, geen netwerk, geen state, geen `jq`.
Dit script draait op de machine van iedereen die de repo kloont en moet in één
blik te auditeren zijn.

Overwogen en niet gedaan: een `activate.sh` die de MCP opzet (lost oorzaak 1
op, die zich niet voordeed — de README-viertrapper dekt de opzet al), en een
`PreToolUse`-gate die grep blokkeert tot `search_docs` liep (handhaaft harder,
maar geeft vals alarm zodra iemand legitiem in de eigen repo leest).

### Bevinding — de guardrail blokkeert agent-geschreven repo-hooks

`workstation-security/common/claude-pre-tool-use.sh` weigert elke schrijfactie
op een pad met `.claude/hooks/`, ongeacht of dat `~/.claude/hooks/` is of dat
van een repo. De agent heeft script en patch dus aangeleverd; installeren en
`git apply` deed Mark met de hand. Dat is het gedrag dat je wil — een agent die
zijn eigen hek zet, is geen hek — en het is hier voor het eerst zichtbaar
geworden op een projecthook in plaats van op de persoonlijke hooks.

### Gewijzigd

- `.claude/hooks/mcp-first.sh` — nieuw; injecteert stap 0 per prompt.
- `.claude/settings.json` — `hooks.UserPromptSubmit` toegevoegd (timeout 5s).
- `scripts/verify.sh` — `shellcheck` dekt nu ook `.claude/hooks/*.sh`, zodat de
  nieuwe hook onder dezelfde lintgate valt als `scripts/`.
- `docs/agents.md` — hook opgenomen in het cataloog; `last_reviewed` bijgewerkt.

## 2026-08-14 — certificaat open.epe.nl verlengd met certswap

Gemeente Epe leverde een verse Sectigo OV-bundel. Geplaatst in
`epe-prod/open-epe-nl-tls` met `certswap apply k8s` — de canonieke procedure
uit `openwoo-app-config/docs/custom-domain-cert.md`, niet met het script
hieronder.

Vooraf getoetst: keten compleet en geverifieerd tegen de trust store, SANs
`open.epe.nl` + `www.open.epe.nl`, en de pubkey-hash van cert, CSR en
privésleutel identiek (RSA 4096). Het oude certificaat verliep 2026-09-02; het
nieuwe loopt tot **2027-02-28**.

`certswap --ingress woo-website` ruimde en passant het achtergebleven
`Certificate`-object op (stond nog op `letsencrypt-prod`, reden
`IncorrectIssuer`) en verving het secret in place. Geverifieerd op het cluster:
`open.epe.nl` serveert `notAfter=Feb 28 23:59:59 2027 GMT`, geen `Certificate`
meer, Argo `epe-prod-reactfront` `Synced/Healthy`.

### Bevinding — privésleutel in een annotatie

Het oude secret droeg `kubectl.kubernetes.io/last-applied-configuration` met
daarin een platte base64-kopie van `tls.key`. Gevolg van de `kubectl apply` in
`scripts/swap_epe_cert.sh` stap 2. De `replace` van certswap heeft de annotatie
weggeschreven, dus dit secret is schoon. **Niet onderzocht** of andere secrets
die langs dezelfde werkwijze zijn aangemaakt hetzelfde probleem hebben.

### Gewijzigd

- `scripts/swap_epe_cert.sh` — header: het script is opgebruikt en is geen
  verlengpad; doorverwezen naar `custom-domain-cert.md`. Alleen commentaar.
- `docs/agents.md` — zelfde markering in het operatie-cataloog.
- Buiten deze repo: `Nextcloud-base` tenantbestand (vervaldatum-comment, de
  enige bewaking die dit cert heeft) en `openwoo-app-config/docs/custom-domain-cert.md`
  (verlengsectie: de genegeerde `--chain`-vlag, `--context`/`--ingress`/`--evidence-dir`,
  en waarom `kubectl create secret tls` geen verlengpad is).

## 2026-08-11 — certificaat-swap Epe: CAA sluit Let's Encrypt uit

### Toegevoegd

`scripts/swap_epe_cert.sh` — zet het Sectigo-certificaat van gemeente Epe over
naar namespace `epe-prod` en zet de tenant op `issuer: none`.

Aanleiding: `certificate/open-epe-nl-tls` bleef falen op een `invalid` order.
Het CAA-record van `epe.nl` staat alleen digicert, certSIGN, kpn, entrust,
sectigo en ssl.com toe — Let's Encrypt staat er niet bij en kan er dus nooit
uitgeven. `open.epe.nl` serveerde ondertussen het fake-certificaat van de
ingress. Het echte certificaat bestond al in de oude namespace `epe`, onder de
naam `epe-prod-reactfront-woo-website-frontend-tls`.

Vijf stappen plus `status` en `cleanup`, elk apart draaibaar en idempotent:
preflight, secret overzetten, merge + push van Nextcloud-base, het lege
`Certificate` opruimen, cluster-verificatie. `all` doet het geheel.

De volgorde zit in de stappen zelf en is de reden dat dit een script is:

- **Het secret gaat eerst**, vóór de merge. Dat mag, want cert-manager schrijft
  alleen bij geslaagde uitgifte en CAA maakt slagen onmogelijk. Zo staat de site
  meteen weer op een geldig cert in plaats van pas na de Argo-sync.
- **Het `Certificate` gaat als laatste.** Stap 4 wacht tot de annotatie
  `cert-manager.io/cluster-issuer` van de ingress verdwenen is en weigert eerder
  te verwijderen: zolang die annotatie er staat, maakt de ingress-shim een
  verwijderd `Certificate` binnen seconden terug.
- Stap 3 weigert zonder secret, en merget `origin/main` binnen vóór onze
  wijziging — anders ketst de push af op non-fast-forward.

De merge lost nooit zelf een conflict op. Een conflict in een tenantbestand is
een inhoudelijke keuze: het script breekt de merge af, geeft de werkboom terug
zoals hij was en noemt de bestanden. Pushen vraagt bevestiging en gebruikt nooit
een `--force`-variant.

Preflight toetst niet alleen dat het bronsecret bestaat, maar ook dat de SAN
`open.epe.nl` dekt. Een naam die klopt met een cert voor een andere host is de
duurste fout die hier mogelijk is.

De secret-kopie loopt via `jq`, dat alle annotaties, labels en ownerReferences
weggooit. Dat is geen netheid maar de kern: zonder Argo-tracking pruunt Argo het
secret niet (`prune: true, selfHeal: true` staat aan op `epe-prod-reactfront`),
en zonder cert-manager-annotaties claimt cert-manager het niet. De privésleutel
gaat alleen door de pipe, nooit naar schijf.

### Gerepareerd — twee defecten die de eerste run blootlegde

- **De conflictlijst noemde te veel.** `git diff --name-only HEAD...ref` toont
  álle verschillen, dus ook bestanden die alleen op de andere kant nieuw zijn en
  probleemloos mergen. In de praktijk stond `tenant-epe-prod.yaml` in de lijst
  terwijl er één echt conflict was. Nu via `git merge-tree --write-tree
  --name-only`: dat doet de merge in het geheugen — geen index, geen werkboom —
  en noemt precies de conflicterende paden.
- **Onbekende argumenten werden stil geslikt.** `status all` liep als `status`,
  omdat alleen `$1` werd gelezen. Wie de uitrol dacht te starten, kreeg een
  rapportje. Nu weigert het script elk argument dat niet `--yes` is.

Stap 5 is een **harde toets**, geen rapportage: zes verwachtingen, exitcode 1 als
er één niet uitkomt. Daarnaast meldt hij de resterende geldigheidsdagen, want met
`issuer: none` bestaat er geen `Certificate` en dus geen expiry-metriek —
`CertificateExpiringSoon` dekt dit certificaat niet. Dat is de enige bewaking die
er is. Het huidige certificaat verloopt **2026-09-02**.

## 2026-08-11 — uitrolscript frontend image-pin en BYO-certificaat

### Toegevoegd

`scripts/rollout_frontend_image_tls.sh` — voert de uitrol uit die over
Nextcloud-base en react-base heen loopt, in de enige volgorde die veilig is.

Trunk-based: het werk staat op `main` in beide repo's, geen branches en geen
PR's. Infra is één beheerder, dus een PR-gate levert hier geen tweede paar ogen
op — alleen stappen tussen een wijziging en het cluster.

De volgorde blijft wél bindend, en dát is de reden dat het een script is en
geen lijstje. React-base maakt de per-tenant image-pin bindend; landt dat op de
remote vóór de drift-uitlijning in Nextcloud-base, dan rolt Argo acht tenants
terug naar `latest`/`dev`, waarvan drie in productie. En het TLS-secret moet
bestaan vóór de tenant-wijziging, anders serveert `canary.accept.openwoo.app`
even geen bruikbaar cert.

Zes stappen plus `rollback`, elk apart draaibaar en idempotent: preflight,
secret zaaien, push Nextcloud-base, push react-base, push openwoo-app-config
(het portaal), cluster-verificatie. `all` doet het geheel.

De volgorde zit in de stappen zelf: stap 3 weigert zonder TLS-secret, stap 4
zolang stap 3 niet op de remote staat, en stap 5 zolang de nieuwe
ApplicationSet niet in het cluster actief is. Dat laatste omdat het nieuwe
portaalformulier registry- en repository-velden aanbiedt die alleen de nieuwe
ApplicationSet begrijpt — eerder uitrollen laat een operator velden zetten die
stil genegeerd worden.

De portal-push start `.github/workflows/image.yml`; die bouwt het image en zet
een `chore(deploy)`-commit waar Argo op uitrolt. Het script wacht op die commit,
zodat "gepusht" niet met "draait" wordt verward.

Stap 5 is een **harde toets**, geen rapportage: zes verwachtingen, exitcode 1
als er één niet uitkomt. Alle zes worden gemeten voordat het script stopt —
anders zie je bij een uitrol alleen de eerste afwijking. Gecontroleerd tegen de
stand vóór uitrol: vijf van de zes falen daar, en precies de juiste vijf.

De verwachte image wordt uit het tenant-bestand zelf afgeleid, niet uit een
constante in het script — anders lopen die twee uiteen zodra iemand de proef
bijstelt.

Pushen gebeurt zonder enige `--force`-variant. Wijst de remote af, dan stopt het
script en verwijst het naar `pull --rebase`; dat is een moment voor een mens.

Stap 2 schrijft sleutelmateriaal naar een `mktemp`-map met 0700 en shredt die
daarna; het secret staat niet in git.

`ARGO_WAIT_SECONDS` en `ARGO_POLL_SECONDS` zijn env-tunable — een trage sync
hoort geen reden te zijn om het script te patchen.

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
wint `GIT_DIR`. Git zet die variabele in de omgeving van elke hook.

**Dit was hier al bekend en al afgevangen** — zie de inzending van 2026-08-08
hieronder: `scripts/verify.sh` unset die variabelen sindsdien vóór pytest.
Deze wijziging verplaatst de bescherming van de *aanroeper* naar de *code*, en
dat dekt twee gevallen die de guard in `verify.sh` niet dekt: de git-aanroepen
van de MCP-server zelf (die kloont repos, en had dus hetzelfde probleem), en
een pytest-run die niet via `verify.sh` loopt.

Aangetoond in een kloon van deze repo, met pytest direct aangeroepen en alleen
`GIT_DIR` gezet — dus buiten de bestaande guard om: de suite muteerde de
werkboom van de repo waar die variabele naar wees (`docs/index.md` gewijzigd,
`docs/other.md` verwijderd). De aanleiding lag in techbook, waar de guard níét
bestond en dezelfde fout 24 fixture-commits in de gepushte branch zette.

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
