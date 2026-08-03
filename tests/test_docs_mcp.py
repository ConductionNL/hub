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


@pytest.fixture(autouse=True)
def geen_lokale_bron(monkeypatch):
    """Isoleer de tests van de fleet-root.

    De lokale bron staat in productie default aan (`DOCS_MCP_LOCAL_ROOT`
    = `..`). Zonder deze isolatie zou een fixture-naam die toevallig
    samenvalt met een echte zusterrepo die repo gaan lezen — de tests
    horen netwerkvrij én fleet-vrij te zijn. Tests die het lokale pad
    expliciet toetsen zetten de variabele zelf.
    """
    monkeypatch.setenv("DOCS_MCP_LOCAL_ROOT", "")


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
        monkeypatch.setenv("DOCS_MCP_INTERNAL_COMPONENTS", "")
        assert c.fetch_import_list()[0].name == "demo"

    def test_publieke_lijst_is_niet_internal(self):
        assert all(not comp.internal for comp in c.parse_import_list(MKDOCS))


INTERNAL = """
repos:
  - section: geheim
    import_url: 'https://github.com/ConductionNL/geheim?branch=main&docs_dir=docs/*'
"""


class TestInternalList:
    """De MCP ziet private componenten; het portaal niet.

    Vóór 2026-08-03 was de publieke importlijst de énige bron voor welke
    componenten bestonden, dus een repo uit de site halen maakte hem ook
    onzichtbaar voor agents. Deze tests houden die twee knoppen gescheiden.
    """

    def _public_only(self, tmp_path, monkeypatch):
        f = tmp_path / "mkdocs.yml"
        f.write_text(MKDOCS)
        monkeypatch.setenv("DOCS_MCP_HANDBOOK_MKDOCS", str(f))

    def test_parse_markeert_internal(self):
        comps = c.parse_internal_list(INTERNAL)
        assert [(x.name, x.internal) for x in comps] == [("geheim", True)]

    def test_leeg_bestand_is_geen_fout(self):
        assert c.parse_internal_list("") == []

    def test_aanvulling_komt_erbij(self, tmp_path, monkeypatch):
        self._public_only(tmp_path, monkeypatch)
        f = tmp_path / "internal.yaml"
        f.write_text(INTERNAL)
        monkeypatch.setenv("DOCS_MCP_INTERNAL_COMPONENTS", str(f))
        comps = c.fetch_import_list()
        assert [(x.name, x.internal) for x in comps] == [
            ("demo", False), ("geheim", True)]

    def test_env_leeg_schakelt_uit(self, tmp_path, monkeypatch):
        self._public_only(tmp_path, monkeypatch)
        monkeypatch.setenv("DOCS_MCP_INTERNAL_COMPONENTS", "")
        assert [x.name for x in c.fetch_import_list()] == ["demo"]

    def test_ontbrekend_bestand_is_geen_fout(self, tmp_path, monkeypatch):
        self._public_only(tmp_path, monkeypatch)
        monkeypatch.setenv("DOCS_MCP_INTERNAL_COMPONENTS",
                           str(tmp_path / "bestaat-niet.yaml"))
        assert [x.name for x in c.fetch_import_list()] == ["demo"]

    def test_publiek_wint_bij_dubbele_naam(self, tmp_path, monkeypatch):
        """Staat een component in beide lijsten, dan publiceert hij — dus
        mag hij niet als 'internal' gemarkeerd raken."""
        self._public_only(tmp_path, monkeypatch)
        f = tmp_path / "internal.yaml"
        f.write_text(INTERNAL.replace("geheim", "demo"))
        monkeypatch.setenv("DOCS_MCP_INTERNAL_COMPONENTS", str(f))
        comps = c.fetch_import_list()
        assert [(x.name, x.internal) for x in comps] == [("demo", False)]

    def test_naam_case_insensitief_gededupliceerd(self, tmp_path, monkeypatch):
        """De lijst schrijft `React-base`, de werkkopie heet `react-base`."""
        self._public_only(tmp_path, monkeypatch)
        f = tmp_path / "internal.yaml"
        f.write_text(INTERNAL.replace("geheim", "DEMO"))
        monkeypatch.setenv("DOCS_MCP_INTERNAL_COMPONENTS", str(f))
        assert [x.name for x in c.fetch_import_list()] == ["demo"]

    def test_meegeleverde_lijst_dekt_de_private_repos(self):
        """De echte internal_components.yaml, niet een fixture: de twee
        private repos moeten erin staan, anders zijn ze onzichtbaar."""
        comps = c.parse_internal_list(c.DEFAULT_INTERNAL_LIST.read_text())
        assert {x.name for x in comps} == {"cluster-config", "KeyCloak"}
        assert all(x.internal for x in comps)

    def test_provenance_meldt_publication(self):
        """Een agent moet in het antwoord zien of `source` publiek is."""
        from docs_mcp import server

        def page(internal):
            return c.Page(component="x", path="index.md", body="", owner=None,
                          last_reviewed=None, source="https://example/x",
                          internal=internal)

        assert server._provenance(page(False))["publication"] == "public"
        assert server._provenance(page(True))["publication"] == "internal"


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


class TestLokaleBron:
    """De fleet-root als bron: sneller, actueler, en eerlijk over herkomst."""

    def _fleet(self, tmp_path, dirname="demo"):
        # make_source_repo legt de repo onder <tmp>/sources/<naam>; die
        # `sources`-map is dus de fleet-root.
        repo = make_source_repo(tmp_path / "fleet", name=dirname)
        return repo.parent, repo

    def test_lokale_werkkopie_wordt_gebruikt_zonder_clone(self, tmp_path,
                                                          monkeypatch):
        fleet, repo = self._fleet(tmp_path)
        monkeypatch.setenv("DOCS_MCP_LOCAL_ROOT", str(fleet))
        # Onbereikbare clone-URL: slaagt dit, dan is er geen netwerk gebruikt.
        comp = c.Component(name="demo", branch="main", docs_dir="docs",
                           clone_url="https://voorbeeld.invalid/Conduction/demo")
        store = c.ContentStore(tmp_path / "cache")
        pages = store.pages(comp)
        assert {p.path for p in pages} == {"index.md", "other.md"}
        assert not (tmp_path / "cache" / "demo").exists()

    def test_casing_verschil_matcht(self, tmp_path, monkeypatch):
        # Importlijst zegt `React-base`, de werkkopie heet `react-base`.
        fleet, _ = self._fleet(tmp_path, dirname="react-base")
        monkeypatch.setenv("DOCS_MCP_LOCAL_ROOT", str(fleet))
        comp = c.Component(name="React-base", branch="main", docs_dir="docs",
                           clone_url="https://voorbeeld.invalid/x/React-base")
        store = c.ContentStore(tmp_path / "cache")
        assert "index.md" in {p.path for p in store.pages(comp)}

    def test_herkomst_meldt_branch_en_ongecommit_werk(self, tmp_path,
                                                     monkeypatch):
        fleet, repo = self._fleet(tmp_path)
        monkeypatch.setenv("DOCS_MCP_LOCAL_ROOT", str(fleet))
        subprocess.run(["git", "checkout", "-q", "-b", "chore/wip"], cwd=repo,
                       check=True)
        (repo / "docs" / "index.md").write_text(PAGE + "\nWIP-regel.\n")
        comp = c.Component(name="demo", branch="main", docs_dir="docs",
                           clone_url="https://voorbeeld.invalid/x/demo")
        store = c.ContentStore(tmp_path / "cache")
        page = store.read_page(comp, "index.md")
        assert "lokale werkkopie" in page.origin
        assert "chore/wip" in page.origin
        assert "importlijst verwacht main" in page.origin
        assert "ONGECOMMITTE" in page.origin

    def test_zonder_lokale_kopie_valt_terug_op_clone(self, tmp_path,
                                                     monkeypatch):
        fleet = tmp_path / "fleet"
        fleet.mkdir()
        monkeypatch.setenv("DOCS_MCP_LOCAL_ROOT", str(fleet))
        repo = make_source_repo(tmp_path)
        store = c.ContentStore(tmp_path / "cache")
        page = store.read_page(make_component(repo), "index.md")
        assert "shallow clone" in page.origin
        assert (tmp_path / "cache" / "demo").exists()


class TestHerkomstURL:
    def test_github_gebruikt_blob_syntax(self):
        url = c._page_url("https://github.com/ConductionNL/cluster-infra",
                          "main", "docs/argocd.md")
        assert url == ("https://github.com/ConductionNL/cluster-infra/"
                       "blob/main/docs/argocd.md")

    def test_forgejo_houdt_src_branch_syntax(self):
        url = c._page_url("https://codeberg.org/Conduction/cluster-infra",
                          "main", "docs/argocd.md")
        assert "/src/branch/main/docs/argocd.md" in url


class TestEnvTunableLimieten:
    def test_defaults_en_override(self, monkeypatch):
        assert c.env_int("DOCS_MCP_GIT_TIMEOUT",
                         c.DEFAULT_GIT_TIMEOUT_SECONDS) == 20
        monkeypatch.setenv("DOCS_MCP_GIT_TIMEOUT", "5")
        assert c.env_int("DOCS_MCP_GIT_TIMEOUT", 20) == 5

    def test_onzin_waarde_valt_terug_op_default(self, monkeypatch):
        monkeypatch.setenv("DOCS_MCP_GIT_TIMEOUT", "geen-getal")
        assert c.env_int("DOCS_MCP_GIT_TIMEOUT", 20) == 20


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
