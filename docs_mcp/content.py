"""Content layer: import list, clones, refresh, page model.

Security invariants (spec docs-mcp, "Hardened local runtime"):
- the read credential never enters clone URLs or git config — it lives
  in a 0600 credential-helper file inside the cache dir;
- page paths are confined to a component's docs tree (no traversal).
"""

import dataclasses
import datetime
import os
import pathlib
import subprocess
import time
import urllib.parse
import urllib.request

import yaml

HANDBOOK_MKDOCS_URL = (
    "https://codeberg.org/Conduction/handbook/raw/branch/main/mkdocs.yml")
DEFAULT_MAX_AGE_SECONDS = 3600

EXCLUDE_PARTS = {".git", ".venv", "node_modules", ".pytest_cache"}


@dataclasses.dataclass(frozen=True)
class Component:
    name: str
    clone_url: str
    branch: str
    docs_dir: str


@dataclasses.dataclass(frozen=True)
class Page:
    component: str
    path: str
    body: str
    owner: str | None
    last_reviewed: str | None
    source: str


def parse_import_list(mkdocs_yaml: str) -> list[Component]:
    """Parse the handbook's multirepo import list (single source of truth)."""
    config = yaml.safe_load(mkdocs_yaml)
    components = []
    for plugin in config.get("plugins", []):
        if not (isinstance(plugin, dict) and "multirepo" in plugin):
            continue
        for repo in plugin["multirepo"].get("repos", []):
            url = urllib.parse.urlparse(repo["import_url"])
            params = urllib.parse.parse_qs(url.query)
            clone_url = f"{url.scheme}://{url.netloc}{url.path}"
            name = url.path.rstrip("/").rsplit("/", 1)[-1]
            components.append(Component(
                name=name,
                clone_url=clone_url,
                branch=params.get("branch", ["main"])[0],
                docs_dir=params.get("docs_dir", ["docs/*"])[0].replace("/*", ""),
            ))
    return components


def fetch_import_list() -> list[Component]:
    override = os.environ.get("DOCS_MCP_HANDBOOK_MKDOCS")
    if override:
        return parse_import_list(pathlib.Path(override).read_text())
    with urllib.request.urlopen(HANDBOOK_MKDOCS_URL, timeout=30) as resp:
        return parse_import_list(resp.read().decode())


class ContentStore:
    """Shallow clones per component, refreshed past max age."""

    def __init__(self, cache_dir: pathlib.Path,
                 max_age: int = DEFAULT_MAX_AGE_SECONDS):
        self.cache_dir = cache_dir
        self.max_age = max_age
        self.cache_dir.mkdir(parents=True, exist_ok=True)
        self.unavailable: dict[str, str] = {}

    def _git_env(self) -> dict:
        env = dict(os.environ)
        env["GIT_TERMINAL_PROMPT"] = "0"  # nooit interactief om creds vragen
        return env

    def _credential_args(self) -> list[str]:
        """Token via een 0600 credential-file — nooit in URL of config."""
        token = os.environ.get("DOCS_READ_TOKEN")
        if not token:
            return []
        cred_file = self.cache_dir / ".git-credentials"
        cred_file.touch(mode=0o600)
        cred_file.write_text(f"https://token:{token}@codeberg.org\n")
        cred_file.chmod(0o600)
        return ["-c", f"credential.helper=store --file={cred_file}"]

    def _refresh(self, comp: Component) -> pathlib.Path | None:
        target = self.cache_dir / comp.name
        stamp = target / ".docs-mcp-stamp"
        if stamp.exists() and time.time() - stamp.stat().st_mtime < self.max_age:
            return target
        creds = self._credential_args()
        if target.exists():
            # Shallow refresh: fetch + hard reset is robuust waar een
            # shallow pull --ff-only dat niet is (lokale kopie is puur cache).
            cmds = [["git", *creds, "-C", str(target), "fetch", "--depth",
                     "1", "origin", comp.branch],
                    ["git", "-C", str(target), "reset", "--hard",
                     "FETCH_HEAD", "--quiet"]]
        else:
            cmds = [["git", *creds, "clone", "--depth", "1", "--branch",
                     comp.branch, comp.clone_url, str(target)]]
        for cmd in cmds:
            result = subprocess.run(cmd, capture_output=True, text=True,
                                    env=self._git_env(), timeout=120)
            if result.returncode != 0:
                self.unavailable[comp.name] = (
                    "niet beschikbaar (clone/refresh faalde; private repo "
                    "zonder DOCS_READ_TOKEN?)")
                return target if target.exists() else None
        stamp.touch()
        return target

    def pages(self, comp: Component) -> list[Page]:
        root = self._refresh(comp)
        if root is None:
            return []
        docs_root = (root / comp.docs_dir).resolve()
        if not docs_root.is_dir():
            return []
        pages = []
        for md in sorted(docs_root.rglob("*.md")):
            if EXCLUDE_PARTS.intersection(md.parts):
                continue
            pages.append(self._load_page(comp, docs_root, md))
        return pages

    def read_page(self, comp: Component, rel_path: str) -> Page:
        root = self._refresh(comp)
        if root is None:
            raise FileNotFoundError(f"{comp.name}: content niet beschikbaar")
        docs_root = (root / comp.docs_dir).resolve()
        # Padbegrenzing: resolve en eis dat het onder docs_root blijft.
        candidate = (docs_root / rel_path).resolve()
        if not candidate.is_relative_to(docs_root):
            raise PermissionError(
                f"pad buiten de docs-boom geweigerd: {rel_path!r}")
        if not candidate.is_file():
            raise FileNotFoundError(f"{comp.name}/{rel_path} bestaat niet")
        return self._load_page(comp, docs_root, candidate)

    def _load_page(self, comp: Component, docs_root: pathlib.Path,
                   md: pathlib.Path) -> Page:
        text = md.read_text(encoding="utf-8", errors="replace")
        meta = _front_matter(text)
        reviewed = meta.get("last_reviewed")
        if isinstance(reviewed, datetime.date):
            reviewed = reviewed.isoformat()
        rel = md.relative_to(docs_root).as_posix()
        return Page(
            component=comp.name, path=rel, body=text,
            owner=meta.get("owner"),
            last_reviewed=reviewed,
            source=f"{comp.clone_url}/src/branch/{comp.branch}/"
                   f"{comp.docs_dir}/{rel}",
        )


def _front_matter(text: str) -> dict:
    if not text.startswith("---\n"):
        return {}
    end = text.find("\n---", 4)
    if end == -1:
        return {}
    try:
        data = yaml.safe_load(text[4:end])
    except yaml.YAMLError:
        return {}
    return data if isinstance(data, dict) else {}
