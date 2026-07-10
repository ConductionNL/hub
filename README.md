# docs-mcp

**MCP-server die het Conduction-handboek ontsluit voor agents** — de
geaggregeerde `/docs` van de deelnemende repos als grondwaarheid, met
herkomst (owner, reviewdatum, bron-URL) bij elk antwoord. Read-only,
stdio-only; de regels en het programma erachter wonen in
[`techbook`](https://codeberg.org/Conduction/techbook), de site in
[`handbook`](https://codeberg.org/Conduction/handbook).

Tools: `list_components` / `search_docs` / `read_page`.
Aansluiten en het beveiligingsmodel: [docs/gebruik.md](docs/gebruik.md).

    uv sync
    ./scripts/verify.sh          # unit tests (netwerkvrij)
    uv run python -m docs_mcp.server   # start (stdio; van elders: uv run --directory <pad> ...)
