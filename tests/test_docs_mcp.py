"""Unit tests voor docs-mcp: importlijst, content, security, search.

Draaien: uv run --with pytest python -m pytest tests/ -q
Netwerkvrij: bronrepos zijn lokale file://-fixtures.
"""

import pathlib
import subprocess

import pytest

from docs_mcp import content as c
from docs_mcp import search as s

MKDOCS = """
plugins:
  - search
  - multirepo:
      cleanup: false
      repos:
        - section: Demo
          import_url: 'https://codeberg.org/Conduction/demo?branch=main&docs_dir=docs/*'
"""

PAGE = """---
last_reviewed: 2026-07-08
owner: mark
---

# Egress proxy

## Allowlist

De squid allowlist bevat exacte hosts, geen wildcards.
"""


def make_source_repo(tmp_path, name="demo"):
    repo = tmp_path / "sources" / name
    (repo / "docs").mkdir(parents=True)
    (repo / "docs" / "index.md").write_text(PAGE)
    (repo / "docs" / "other.md").write_text("# Ander onderwerp\n\nNiets.\n")
    subprocess.run(["git", "init", "-q", "-b", "main"], cwd=repo, check=True)
    subprocess.run(["git", "add", "-A"], cwd=repo, check=True)
    subprocess.run(["git", "-c", "user.email=t@t", "-c", "user.name=t",
                    "commit", "-qm", "init"], cwd=repo, check=True)
    return repo


def make_component(repo, name="demo"):
    return c.Component(name=name, clone_url=f"file://{repo}",
                       branch="main", docs_dir="docs")


class TestImportList:
    def test_parse(self):
        comps = c.parse_import_list(MKDOCS)
        assert len(comps) == 1
        comp = comps[0]
        assert comp.name == "demo"
        assert comp.clone_url == "https://codeberg.org/Conduction/demo"
        assert comp.branch == "main"
        assert comp.docs_dir == "docs"

    def test_env_override(self, tmp_path, monkeypatch):
        f = tmp_path / "mkdocs.yml"
        f.write_text(MKDOCS)
        monkeypatch.setenv("DOCS_MCP_HANDBOOK_MKDOCS", str(f))
        assert c.fetch_import_list()[0].name == "demo"


class TestContentStore:
    def test_pages_and_provenance(self, tmp_path):
        repo = make_source_repo(tmp_path)
        store = c.ContentStore(tmp_path / "cache")
        pages = store.pages(make_component(repo))
        assert {p.path for p in pages} == {"index.md", "other.md"}
        page = [p for p in pages if p.path == "index.md"][0]
        assert page.owner == "mark"
        assert page.last_reviewed == "2026-07-08"
        assert "src/branch/main/docs/index.md" in page.source

    def test_read_page(self, tmp_path):
        repo = make_source_repo(tmp_path)
        store = c.ContentStore(tmp_path / "cache")
        page = store.read_page(make_component(repo), "index.md")
        assert "Egress proxy" in page.body

    def test_path_traversal_rejected(self, tmp_path):
        repo = make_source_repo(tmp_path)
        store = c.ContentStore(tmp_path / "cache")
        with pytest.raises(PermissionError):
            store.read_page(make_component(repo), "../../../etc/passwd")

    def test_missing_page(self, tmp_path):
        repo = make_source_repo(tmp_path)
        store = c.ContentStore(tmp_path / "cache")
        with pytest.raises(FileNotFoundError):
            store.read_page(make_component(repo), "bestaat-niet.md")

    def test_unavailable_component_not_fatal(self, tmp_path):
        store = c.ContentStore(tmp_path / "cache")
        broken = c.Component(name="weg", branch="main", docs_dir="docs",
                             clone_url=f"file://{tmp_path}/nergens")
        assert store.pages(broken) == []
        assert "weg" in store.unavailable

    def test_token_never_in_git_config(self, tmp_path, monkeypatch):
        monkeypatch.setenv("DOCS_READ_TOKEN", "SUPERGEHEIM123")
        repo = make_source_repo(tmp_path)
        store = c.ContentStore(tmp_path / "cache")
        store.pages(make_component(repo))
        git_config = (tmp_path / "cache" / "demo" / ".git" / "config")
        assert "SUPERGEHEIM123" not in git_config.read_text()
        cred = tmp_path / "cache" / ".git-credentials"
        assert cred.exists()
        assert (cred.stat().st_mode & 0o777) == 0o600

    def test_refresh_picks_up_changes(self, tmp_path):
        repo = make_source_repo(tmp_path)
        store = c.ContentStore(tmp_path / "cache", max_age=0)
        comp = make_component(repo)
        store.pages(comp)
        (repo / "docs" / "nieuw.md").write_text("# Nieuw\n")
        subprocess.run(["git", "add", "-A"], cwd=repo, check=True)
        subprocess.run(["git", "-c", "user.email=t@t", "-c", "user.name=t",
                        "commit", "-qm", "meer"], cwd=repo, check=True)
        assert "nieuw.md" in {p.path for p in store.pages(comp)}


class TestSearch:
    def _pages(self, tmp_path):
        repo = make_source_repo(tmp_path)
        return c.ContentStore(tmp_path / "cache").pages(make_component(repo))

    def test_title_beats_body(self, tmp_path):
        hits = s.search(self._pages(tmp_path), "egress")
        assert hits[0].page.path == "index.md"
        assert hits[0].score >= s.TITLE_WEIGHT

    def test_no_hits(self, tmp_path):
        assert s.search(self._pages(tmp_path), "kwantumfysica") == []

    def test_snippet_contains_term_context(self, tmp_path):
        hits = s.search(self._pages(tmp_path), "allowlist")
        assert "allowlist" in hits[0].snippet.lower()


class TestSymlinkGuard:
    def test_symlink_outside_tree_skipped(self, tmp_path):
        repo = make_source_repo(tmp_path)
        geheim = tmp_path / "geheim.md"
        geheim.write_text("# prive-inhoud buiten de boom\n")
        (repo / "docs" / "lek.md").symlink_to(geheim)
        subprocess.run(["git", "add", "-A"], cwd=repo, check=True)
        subprocess.run(["git", "-c", "user.email=t@t", "-c", "user.name=t",
                        "commit", "-qm", "symlink"], cwd=repo, check=True)
        store = c.ContentStore(tmp_path / "cache")
        paths = {p.path for p in store.pages(make_component(repo))}
        assert "lek.md" not in paths
        assert "index.md" in paths
