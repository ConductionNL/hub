# hub

**Dit is de agent-ingang van Conduction: cockpit én handboek-MCP in
één.** Open hier je Claude-sessie en werk met alle componenten; de
meegeleverde MCP-server (`conduction-docs`) serveert de geaggregeerde
`/docs` van de deelnemende repos als grondwaarheid, met herkomst
(owner, reviewdatum, bron-URL) bij elk antwoord. De regels wonen in
[`techbook`](https://codeberg.org/Conduction/techbook), de site in
[`handbook`](https://codeberg.org/Conduction/handbook).

## Gebruik (cockpit)

    git clone https://codeberg.org/Conduction/hub.git ~/CONDUCTION/hub
    cd ~/CONDUCTION/hub && uv sync
    ./scripts/clone_all.sh     # kloont/ververst alle deelnemende repos ernaast
    claude                     # sessie met toegang tot alles + handboek-MCP

Werk je aan één component, open Claude dan gewoon dáár — elke repo
registreert dezelfde MCP en heeft zijn eigen operatie-cataloog
(`docs/agents.md`).

## De MCP-server

Tools: `list_components` / `search_docs` / `read_page` — read-only,
stdio-only. Aansluiten buiten deze map en het beveiligingsmodel:
[docs/gebruik.md](docs/gebruik.md).

    ./scripts/verify.sh                # unit tests + lint (pre-push gate)
    uv run python -m docs_mcp.server   # start met de hand (stdio)
