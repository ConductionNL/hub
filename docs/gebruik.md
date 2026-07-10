---
last_reviewed: 2026-07-10
owner: mark
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
| `DOCS_MCP_HANDBOOK_MKDOCS` | lokaal mkdocs.yml i.p.v. Codeberg | (netwerk) |

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
