# hub

**Dit is de agent-ingang van Conduction: cockpit én handboek-MCP in
één.** Open hier je Claude-sessie en werk met alle componenten; de
meegeleverde MCP-server (`conduction-docs`) serveert de geaggregeerde
`/docs` van de deelnemende repos als grondwaarheid, met herkomst
(owner, reviewdatum, bron-URL, en via `origin` de gebruikte kopie) bij
elk antwoord. De regels wonen in
[`techbook`](https://github.com/ConductionNL/techbook), de site in
[`handbook`](https://github.com/ConductionNL/handbook).

## Gebruik (cockpit)

    git clone https://github.com/ConductionNL/hub.git ~/CONDUCTION/hub
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

De bron is de werkkopie die al naast deze map staat; alleen wat lokaal
ontbreekt wordt gekloond. Een koud antwoord duurt daardoor ~0,1s in
plaats van over de tool-limiet te lopen. De prijs: een werkkopie kan op
een feature-branch staan of ongecommit werk hebben — het `origin`-veld
bij elk antwoord maakt dat zichtbaar, en agents horen het te citeren.

    ./scripts/verify.sh                # unit tests + lint (pre-push gate)
    uv run python -m docs_mcp.server   # start met de hand (stdio)
