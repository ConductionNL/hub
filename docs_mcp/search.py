"""Kale tekstsearch over pagina's: titel > koppen > body, geen embeddings."""

import dataclasses
import re

from docs_mcp.content import Page

TITLE_WEIGHT = 5
HEADING_WEIGHT = 3
BODY_WEIGHT = 1
SNIPPET_CHARS = 240


@dataclasses.dataclass(frozen=True)
class Hit:
    page: Page
    score: int
    snippet: str


def _terms(query: str) -> list[str]:
    return [t for t in re.split(r"\W+", query.lower()) if len(t) >= 2]


def _title(page: Page) -> str:
    for line in page.body.splitlines():
        if line.startswith("# "):
            return line[2:].strip()
    return page.path


def _headings(page: Page) -> str:
    return " ".join(l.lstrip("#").strip()
                    for l in page.body.splitlines() if l.startswith("#"))


def _snippet(body: str, term: str) -> str:
    lower = body.lower()
    idx = lower.find(term)
    if idx == -1:
        return body[:SNIPPET_CHARS].strip()
    start = max(0, idx - SNIPPET_CHARS // 2)
    return body[start:start + SNIPPET_CHARS].strip()


def search(pages: list[Page], query: str, limit: int = 10) -> list[Hit]:
    terms = _terms(query)
    if not terms:
        return []
    hits = []
    for page in pages:
        title = _title(page).lower()
        headings = _headings(page).lower()
        body = page.body.lower()
        score = 0
        for term in terms:
            if term in title:
                score += TITLE_WEIGHT
            if term in headings:
                score += HEADING_WEIGHT
            score += min(body.count(term), 5) * BODY_WEIGHT
        if score > 0:
            hits.append(Hit(page=page, score=score,
                            snippet=_snippet(page.body, terms[0])))
    hits.sort(key=lambda h: (-h.score, h.page.component, h.page.path))
    return hits[:limit]
