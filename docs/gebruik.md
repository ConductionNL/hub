---
last_reviewed: 2026-07-10
owner: info@conduction.nl
---

# Gebruik en beveiliging

## Aansluiten (stdio, lokaal)

In een `.mcp.json` van een repo of agent-omgeving:

```json
{
  "mcpServers": {
    "conduction-docs": {
      "command": "uv",
      "args": ["run", "--directory", "/pad/naar/hub",
               "python", "-m", "docs_mcp.server"]
    }
  }
}
```

Omgevingsvariabelen (alle optioneel):

| Variabele | Doel | Default |
|---|---|---|
| `DOCS_READ_TOKEN` | leestoegang tot private bronrepos | geen (private repos afwezig) |
| `DOCS_MCP_CACHE` | cache-locatie voor de clones | `~/.cache/docs-mcp` |
| `DOCS_MCP_MAX_AGE` | verversing in seconden | `3600` |
| `DOCS_MCP_HANDBOOK_MKDOCS` | lokaal mkdocs.yml i.p.v. de netwerk-bron | (netwerk) |
| `DOCS_MCP_LOCAL_ROOT` | fleet-root met de zusterrepos als werkkopie; leeg = altijd klonen | `..` |
| `DOCS_MCP_GIT_TIMEOUT` | timeout per git-aanroep, seconden | `20` |
| `DOCS_MCP_IMPORT_LIST_TIMEOUT` | timeout voor het ophalen van de importlijst, seconden | `30` |

## Bron: lokale werkkopie eerst

Staat een component al als werkkopie onder `DOCS_MCP_LOCAL_ROOT`, dan
leest de MCP die map direct; alleen componenten die lokaal ontbreken
worden shallow gekloond. Reden: de cockpit heeft de zusterrepos al onder
`../` staan, en klonen kostte per component een netwerk-ronde. Met negen
componenten paste dat niet binnen de 120s die een agent-call heeft — de
MCP was daardoor in de praktijk onbruikbaar en werd omzeild. Koud
antwoorden duurt nu ~0,1s.

Namen worden case-insensitief gematcht: de importlijst schrijft
`React-base`, de werkkopie heet `react-base`.

De prijs is dat een werkkopie op een feature-branch kan staan of
ongecommit werk kan hebben. Daarom levert elke pagina een `origin`-veld
naast de herkomst, dat de gebruikte bron benoemt — inclusief branch,
een waarschuwing als die afwijkt van de importlijst, en of er
ongecommitte wijzigingen zijn. Een agent hoort dat te citeren: een
WIP-branch is geen grondwaarheid. Zet `DOCS_MCP_LOCAL_ROOT=""` om
uitsluitend van de remote te lezen.

Dat de gedocumenteerde start werkt, is een geteste bewering
(uitvoerbare documentatie):

```bash verify
uv run python -c "from docs_mcp import content, search, server"
```

## Tools

- `list_components()` — componenten + pagina's (met notice als een
  private repo niet leesbaar is)
- `search_docs(query, limit)` — zoeken (titel > koppen > tekst)
- `read_page(component, path)` — één pagina, altijd met herkomst
  (owner, last_reviewed, bron-URL) — citeer die in antwoorden

## Cockpit-guardrails: afgedwongen vs conventie

Sinds 2026-07-10 zijn cluster-mutaties vanuit cockpit-sessies **technisch
geblokkeerd** (deny-regels in `.claude/settings.json`): `kubectl
apply/delete/patch/scale/exec/...`, `argocd app sync/set/delete`, `helm
install/upgrade/uninstall` en `sops` worden geweigerd, ongeacht wat een
sessie probeert. Leesoperaties (`kubectl get/describe/logs`, `kubectl
kustomize` voor de verify-gates) blijven werken.

**Conventie blijft** (niet technisch afdwingbaar hier): geen
prod-kubeconfig in de default-omgeving van de cockpit-machine, pushes
door een mens, en de per-component catalogen. ISO-framing: de
deny-lijst is de werkende control, de conventies zijn de beschreven
control met de pre-push gates als detectie.

## Beveiligingsmodel

- **Geen netwerkpoort**: stdio-transport; de server is een lokaal
  proces onder jouw account. Een gehoste variant komt pas achter de
  oauth2-proxy → Keycloak-laag van `add-portal-access-split`.
- **Read-only**: er bestaan geen schrijf-tools; wijzigingen aan docs
  gaan via PR's in de bronrepo.
- **Padbegrenzing**: `read_page` weigert paden buiten de docs-boom van
  de component (traversal getest).
- **Token-hygiëne**: `DOCS_READ_TOKEN` komt nooit in clone-URL's,
  git-config, logs of tool-output; hij leeft in een 0600
  credential-bestand in de cache (getest).
- **Eén waarheid**: de importlijst wordt live uit het handboek gelezen;
  er is geen tweede, eigen curatielaag.
- **Pinned + getest**: dependencies vastgepind; 12 unit tests inclusief
  de traversal- en token-lek-scenario's.

Of user-breed, buiten elke repo:

```
claude mcp add --scope user conduction-docs -- \
  uv run --directory /pad/naar/hub python -m docs_mcp.server
```

> Let op: `--directory`, niet `--project` — dat laatste activeert wel de
> venv maar niet de map, en dit package is bewust niet geïnstalleerd.
