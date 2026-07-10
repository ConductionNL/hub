# Changelog

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
