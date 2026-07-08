"""docs-mcp — MCP-ingang tot het Conduction-handboek voor agents.

Read-only, stdio-only (geen netwerkpoort). Bron van waarheid = de
importlijst van het handboek; content wordt shallow gekloond en na de
max-age ververst. Zie openspec spec `docs-mcp` in techbook.

Start (bijv. in .mcp.json):
  uv run --project /pad/naar/docs-mcp python -m docs_mcp.server
"""

import os
import pathlib

from mcp.server.fastmcp import FastMCP

from docs_mcp import content as content_mod
from docs_mcp import search as search_mod

mcp = FastMCP("conduction-docs")

_store: content_mod.ContentStore | None = None
_components: list[content_mod.Component] | None = None


def _init():
    global _store, _components
    if _store is None:
        cache = pathlib.Path(os.environ.get(
            "DOCS_MCP_CACHE",
            pathlib.Path.home() / ".cache" / "docs-mcp"))
        max_age = int(os.environ.get("DOCS_MCP_MAX_AGE", "3600"))
        _store = content_mod.ContentStore(cache, max_age=max_age)
        _components = content_mod.fetch_import_list()
    return _store, _components


def _component(name: str) -> content_mod.Component:
    _, comps = _init()
    for c in comps:
        if c.name.lower() == name.lower():
            return c
    known = ", ".join(c.name for c in comps)
    raise ValueError(f"onbekende component {name!r}; bekend: {known}")


def _provenance(p: content_mod.Page) -> dict:
    return {"component": p.component, "path": p.path, "owner": p.owner,
            "last_reviewed": p.last_reviewed, "source": p.source}


@mcp.tool()
def list_components() -> list[dict]:
    """De deelnemende componenten van het handboek, met hun pagina's."""
    store, comps = _init()
    out = []
    for c in comps:
        pages = store.pages(c)
        entry = {"component": c.name,
                 "pages": [p.path for p in pages]}
        if c.name in store.unavailable:
            entry["notice"] = store.unavailable[c.name]
        out.append(entry)
    return out


@mcp.tool()
def read_page(component: str, path: str) -> dict:
    """Lees één documentatiepagina (markdown) inclusief herkomst.

    De herkomst (owner, last_reviewed, source) hoort in antwoorden
    geciteerd te worden; de handboek-inhoud gaat boven modelkennis.
    """
    store, _ = _init()
    page = store.read_page(_component(component), path)
    return {**_provenance(page), "body": page.body}


@mcp.tool()
def search_docs(query: str, limit: int = 10) -> list[dict]:
    """Zoek over alle componenten (titel > koppen > tekst)."""
    store, comps = _init()
    pages = [p for c in comps for p in store.pages(c)]
    return [{**_provenance(h.page), "score": h.score, "snippet": h.snippet}
            for h in search_mod.search(pages, query, limit=limit)]


def main():
    mcp.run()  # stdio


if __name__ == "__main__":
    main()
