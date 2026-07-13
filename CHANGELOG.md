# Changelog

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
