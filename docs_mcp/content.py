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
    "https://raw.githubusercontent.com/ConductionNL/handbook/main/mkdocs.yml")
DEFAULT_MAX_AGE_SECONDS = 3600

# Variabelen die een git-aanroep naar een ándere repo omleiden. Noch `cwd=`
# noch `-C <pad>` overrulet ze: staat GIT_DIR gezet, dan wint GIT_DIR. Git
# zet ze zelf in de omgeving van elke hook, en deze code draait onder meer
# via `scripts/verify.sh`, dat als pre-push hook is gedeclareerd.
#
# Dit is geen theoretisch risico. Aangetoond op 2026-08-10 in een kloon van
# deze repo: met alleen GIT_DIR gezet muteerde de testsuite de werkboom van
# de repo waar die variabele naar wees (`docs/index.md` gewijzigd,
# `docs/other.md` verwijderd). Zonder GIT_DIR gebeurt er niets — daarom valt
# het bij los draaien nooit op.
REPO_ENV_VARS = (
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_COMMON_DIR",
    "GIT_NAMESPACE",
    "GIT_CEILING_DIRECTORIES",
    "GIT_PREFIX",
    "GIT_INDEX_VERSION",
)


def clean_git_env(environ=None) -> dict:
    """De omgeving zonder de variabelen die git naar een andere repo omleiden.

    Gebruik dit voor élke git-aanroep — ook in tests die fixture-repo's
    aanmaken. Zie REPO_ENV_VARS voor het waarom.
    """
    env = dict(os.environ if environ is None else environ)
    for var in REPO_ENV_VARS:
        env.pop(var, None)
    return env

# Limieten zijn env-tunable, nooit hardgecodeerd. De git-timeout staat
# bewust ruim onder de 120s tool-limiet van een agent-call: één trage of
# onbereikbare remote mag nooit de hele call opeten (dat was precies het
# gedrag waardoor `search_docs` koud niet binnen één call antwoordde).
DEFAULT_GIT_TIMEOUT_SECONDS = 20
DEFAULT_IMPORT_LIST_TIMEOUT_SECONDS = 30

# Fleet-root waaronder de zusterrepos als werkkopie staan. Leeg zetten
# schakelt de lokale bron uit en dwingt netwerk-clones af.
DEFAULT_LOCAL_ROOT = ".."

# Interne componenten (niet publiek gepubliceerd). Naast de package, niet
# relatief aan de cwd: de MCP start vanuit willekeurige werkmappen.
DEFAULT_INTERNAL_LIST = pathlib.Path(__file__).with_name(
    "internal_components.yaml")

EXCLUDE_PARTS = {".git", ".venv", "node_modules", ".pytest_cache"}


def env_int(name: str, default: int) -> int:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    try:
        return int(raw)
    except ValueError:
        return default


def _page_url(clone_url: str, branch: str, rel_path: str) -> str:
    """Web-URL naar een bestand — de syntax verschilt per forge.

    Forgejo/Codeberg gebruikt /src/branch/<branch>/, GitHub /blob/<branch>/.
    Host-agnostisch houden is de voorwaarde om de importlijst naar GitHub
    te kunnen omzetten zonder dat de herkomst stille 404's gaat opleveren.
    """
    host = urllib.parse.urlparse(clone_url).netloc.lower()
    infix = "blob" if host.endswith("github.com") else "src/branch"
    return f"{clone_url}/{infix}/{branch}/{rel_path}"


@dataclasses.dataclass(frozen=True)
class Component:
    name: str
    clone_url: str
    branch: str
    docs_dir: str
    # True = alleen voor de MCP, niet op de publieke site. Zie
    # internal_components.yaml. Een agent die hieruit citeert moet weten
    # dat de bron-URL niet publiek open te klikken is.
    internal: bool = False


@dataclasses.dataclass(frozen=True)
class Page:
    component: str
    path: str
    body: str
    owner: str | None
    last_reviewed: str | None
    source: str
    # Wélke kopie deze pagina opleverde. Een lokale werkkopie kan op een
    # feature-branch staan met ongecommitte wijzigingen; dan is de inhoud
    # géén weergave van `source`. Dat moet zichtbaar zijn in het antwoord,
    # anders presenteert de MCP een WIP-branch als grondwaarheid.
    origin: str = "remote"
    # Uit een component die niet publiek gepubliceerd wordt. Citeer je dit
    # naar buiten, dan is `source` voor de ontvanger niet te openen.
    internal: bool = False


def _components_from_repos(repos: list, *, internal: bool) -> list[Component]:
    """Zet een `repos:`-lijst (mkdocs-multirepo-vorm) om naar Components.

    `internal` is de default voor deze lijst. Een entry mag hem overrulen met
    `publication: public|internal`. Dat is nodig voor repo's die publiek zijn
    maar zichzelf niet importeren: `handbook` is de site en `techbook` is
    normatief, beide publiek op GitHub, en geen van beide staat in de
    publieke importlijst. Zonder override zouden ze als `internal` gemeld
    worden en zou elk antwoord beweren dat hun `source`-URL niet open te
    klikken is — wat niet waar is.
    """
    components = []
    for repo in repos or []:
        url = urllib.parse.urlparse(repo["import_url"])
        params = urllib.parse.parse_qs(url.query)
        clone_url = f"{url.scheme}://{url.netloc}{url.path}"
        name = url.path.rstrip("/").rsplit("/", 1)[-1]
        publication = str(repo.get("publication", "")).strip().lower()
        if publication not in ("", "public", "internal"):
            raise ValueError(
                f"onbekende publication '{publication}' voor {name}; "
                "gebruik 'public' of 'internal'")
        components.append(Component(
            name=name,
            clone_url=clone_url,
            branch=params.get("branch", ["main"])[0],
            docs_dir=params.get("docs_dir", ["docs/*"])[0].replace("/*", ""),
            internal=internal if not publication else publication == "internal",
        ))
    return components


def parse_import_list(mkdocs_yaml: str) -> list[Component]:
    """Parse de publieke importlijst van het handboek (de trust root)."""
    config = yaml.safe_load(mkdocs_yaml)
    components = []
    for plugin in config.get("plugins", []):
        if not (isinstance(plugin, dict) and "multirepo" in plugin):
            continue
        components.extend(_components_from_repos(
            plugin["multirepo"].get("repos", []), internal=False))
    return components


def parse_internal_list(list_yaml: str) -> list[Component]:
    """Parse de interne aanvulling (`repos:` op topniveau)."""
    config = yaml.safe_load(list_yaml) or {}
    return _components_from_repos(config.get("repos", []), internal=True)


def load_internal_list() -> list[Component]:
    """Interne componenten: zichtbaar voor de MCP, niet voor het portaal.

    Pad is env-tunable (`DOCS_MCP_INTERNAL_COMPONENTS`); expliciet leeg
    zetten schakelt de aanvulling uit, dan ziet de MCP precies wat het
    portaal publiceert. Een ontbrekend bestand is geen fout — de MCP moet
    blijven werken zonder interne lijst.
    """
    raw = os.environ.get("DOCS_MCP_INTERNAL_COMPONENTS")
    if raw is not None and not raw.strip():
        return []
    path = pathlib.Path(raw) if raw else DEFAULT_INTERNAL_LIST
    if not path.is_file():
        return []
    return parse_internal_list(path.read_text())


def _merge(public: list[Component],
           internal: list[Component]) -> list[Component]:
    """Publiek + intern, zonder dubbelen. Publiek wint: dat publiceert.

    Namen case-insensitief vergeleken, net als de werkkopie-matching
    (`React-base` in de lijst, `react-base` op schijf).
    """
    seen = {c.name.lower() for c in public}
    return public + [c for c in internal if c.name.lower() not in seen]


def fetch_import_list() -> list[Component]:
    override = os.environ.get("DOCS_MCP_HANDBOOK_MKDOCS")
    if override:
        public = parse_import_list(pathlib.Path(override).read_text())
    else:
        timeout = env_int("DOCS_MCP_IMPORT_LIST_TIMEOUT",
                          DEFAULT_IMPORT_LIST_TIMEOUT_SECONDS)
        with urllib.request.urlopen(HANDBOOK_MKDOCS_URL,
                                    timeout=timeout) as resp:
            public = parse_import_list(resp.read().decode())
    return _merge(public, load_internal_list())


class ContentStore:
    """Content per component: lokale werkkopie eerst, anders shallow clone.

    Staat een component al als werkkopie onder de fleet-root
    (`DOCS_MCP_LOCAL_ROOT`, default `..`), dan is dat de bron — dat is
    zowel sneller als actueler dan een mirror. Componenten die lokaal
    ontbreken worden shallow gekloond en na `max_age` ververst.
    """

    def __init__(self, cache_dir: pathlib.Path,
                 max_age: int = DEFAULT_MAX_AGE_SECONDS,
                 local_root: pathlib.Path | None = None):
        self.cache_dir = cache_dir
        self.max_age = max_age
        self.cache_dir.mkdir(parents=True, exist_ok=True)
        self.unavailable: dict[str, str] = {}
        if local_root is None:
            raw = os.environ.get("DOCS_MCP_LOCAL_ROOT", DEFAULT_LOCAL_ROOT)
            local_root = pathlib.Path(raw).expanduser() if raw.strip() else None
        self.local_root = local_root
        # Herkomst per component, gevuld door _refresh; _load_page leest het.
        self._origin: dict[str, str] = {}
        self._local_cache: dict[str, pathlib.Path | None] = {}

    def _git(self, *args: str, cwd: pathlib.Path | None = None,
             creds: list[str] | None = None) -> subprocess.CompletedProcess:
        cmd = ["git", *(creds or []), *args]
        return subprocess.run(
            cmd, capture_output=True, text=True, cwd=cwd, env=self._git_env(),
            timeout=env_int("DOCS_MCP_GIT_TIMEOUT",
                            DEFAULT_GIT_TIMEOUT_SECONDS))

    def _local_path(self, comp: Component) -> pathlib.Path | None:
        """De werkkopie van deze component onder de fleet-root, of None.

        Namen worden case-insensitief gematcht: de importlijst schrijft
        `React-base` waar de werkkopie `react-base` heet.
        """
        if comp.name in self._local_cache:
            return self._local_cache[comp.name]
        found = None
        if self.local_root and self.local_root.is_dir():
            for cand in sorted(self.local_root.iterdir()):
                if cand.name.lower() != comp.name.lower():
                    continue
                if (cand / ".git").exists() and (cand / comp.docs_dir).is_dir():
                    found = cand
                break
        self._local_cache[comp.name] = found
        return found

    def _local_origin(self, path: pathlib.Path, comp: Component) -> str:
        """Beschrijf de lokale kopie: branch en of er ongecommit werk staat."""
        head = self._git("-C", str(path), "rev-parse", "--abbrev-ref", "HEAD")
        branch = head.stdout.strip() if head.returncode == 0 else "?"
        status = self._git("-C", str(path), "status", "--porcelain")
        dirty = bool(status.stdout.strip()) if status.returncode == 0 else False
        note = f"lokale werkkopie {path} op branch {branch}"
        if branch != comp.branch:
            note += f" (importlijst verwacht {comp.branch})"
        if dirty:
            note += " met ONGECOMMITTE wijzigingen"
        return note

    def _git_env(self) -> dict:
        env = clean_git_env()
        env["GIT_TERMINAL_PROMPT"] = "0"  # nooit interactief om creds vragen
        return env

    def _credential_args(self, comp: Component | None = None) -> list[str]:
        """Token via een 0600 credential-file — nooit in URL of config.

        De host komt uit de clone-URL van de component, niet uit een
        hardgecodeerde forge: anders is het token waardeloos zodra de
        importlijst naar een andere host wijst.
        """
        token = os.environ.get("DOCS_READ_TOKEN")
        if not token:
            return []
        host = ""
        if comp is not None:
            host = urllib.parse.urlparse(comp.clone_url).netloc
        if not host:
            host = urllib.parse.urlparse(HANDBOOK_MKDOCS_URL).netloc
        cred_file = self.cache_dir / ".git-credentials"
        cred_file.touch(mode=0o600)
        cred_file.write_text(f"https://token:{token}@{host}\n")
        cred_file.chmod(0o600)
        return ["-c", f"credential.helper=store --file={cred_file}"]

    def _refresh(self, comp: Component) -> pathlib.Path | None:
        # Staat de component al als werkkopie onder de fleet-root, dan is
        # dát de bron: geen egress, geen wachttijd. Netwerk-clone blijft de
        # fallback voor componenten die lokaal ontbreken.
        local = self._local_path(comp)
        if local is not None:
            self._origin[comp.name] = self._local_origin(local, comp)
            return local

        target = self.cache_dir / comp.name
        self._origin[comp.name] = f"shallow clone van {comp.clone_url}"
        stamp = target / ".docs-mcp-stamp"
        if stamp.exists() and time.time() - stamp.stat().st_mtime < self.max_age:
            return target
        creds = self._credential_args(comp)
        if target.exists():
            # Shallow refresh: fetch + hard reset is robuust waar een
            # shallow pull --ff-only dat niet is (lokale kopie is puur cache).
            cmds = [["-C", str(target), "fetch", "--depth", "1", "origin",
                     comp.branch],
                    ["-C", str(target), "reset", "--hard", "FETCH_HEAD",
                     "--quiet"]]
        else:
            cmds = [["clone", "--depth", "1", "--branch", comp.branch,
                     comp.clone_url, str(target)]]
        for args in cmds:
            try:
                result = self._git(*args, creds=creds)
            except subprocess.TimeoutExpired:
                self.unavailable[comp.name] = (
                    "niet beschikbaar (clone/refresh over de timeout; zie "
                    "DOCS_MCP_GIT_TIMEOUT)")
                return target if target.exists() else None
            if result.returncode != 0:
                self.unavailable[comp.name] = (
                    "niet beschikbaar (clone/refresh faalde; private repo "
                    "zonder DOCS_READ_TOKEN?)")
                return target if target.exists() else None
            creds = None  # alleen de eerste (netwerk-)stap heeft creds nodig
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
            # Symlink-guard (zelfde begrenzing als read_page): een link
            # die buiten de docs-boom wijst wordt overgeslagen, nooit
            # gevolgd — anders kan een bronrepo lokale bestanden lekken.
            if not md.resolve().is_relative_to(docs_root):
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
            source=_page_url(comp.clone_url, comp.branch,
                             f"{comp.docs_dir}/{rel}"),
            origin=self._origin.get(comp.name, "remote"),
            internal=comp.internal,
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
