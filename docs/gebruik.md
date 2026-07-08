---
last_reviewed: 2026-07-08
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
      "args": ["run", "--project", "/pad/naar/docs-mcp",
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

## Tools

- `list_components()` — componenten + pagina's (met notice als een
  private repo niet leesbaar is)
- `search_docs(query, limit)` — zoeken (titel > koppen > tekst)
- `read_page(component, path)` — één pagina, altijd met herkomst
  (owner, last_reviewed, bron-URL) — citeer die in antwoorden

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
