#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# role: installer
#
# scripts/onboard.sh — richt een werkplek in voor het Conduction-platformbeheer.
#
# Eén script, van een verse machine naar een werkende sessie: de fleet gekloond,
# de agent-guardrails geïnstalleerd, de handboek-MCP bereikbaar, en een geldig
# kubeconfig per cluster.
#
# ## De enige handmatige voorwaarde
#
# Het EMK service-account-kubeconfig moet in `~/.kube/` staan. Dat vraag je met
# de hand aan bij Fuga Cloud; het is persoonsgebonden, staat nooit in git, en
# dit script kan het niet voor je regelen. Alles daarna wel.
#
# Het bestand heet per persoon anders (`emk-sa-<project>_<naam>-conduction.yml`),
# dus dit script zoekt het met een glob in plaats van een naam te verwachten.
# Reden: de toolchain-variant van deze stap had het pad van één persoon
# hardgecodeerd, zonder env-override, waardoor de eerste handeling van een
# nieuwe beheerder faalde op een bestand dat niet van hem was.
#
# ## Waarom de Gardener-call hier staat en niet in toolchain
#
# Het genereren van een cluster-kubeconfig is één gedocumenteerde
# Gardener-API-aanroep (`adminkubeconfig`). Die staat hier zodat een nieuwe
# beheerder niet eerst een privérepo met een persoonsgebonden pad hoeft te
# installeren om te kunnen inloggen. Twee verschillen met de variant die daar
# staat: het pad naar het service-account wordt gevonden in plaats van geraden,
# en het doelbestand wordt pas overschreven als de call is geslaagd — die
# variant truncate het bestand vóór de aanroep, dus een mislukte login liet je
# zonder de oude kubeconfig achter.
#
# ## Veiligheid
#
# Zonder `--apply` wijzigt dit script niets: het rapporteert wat het zou doen.
# `~/.kube/config` wordt vóór overschrijven geback-upt. Het script print nooit
# de inhoud van een kubeconfig of een token.
#
# Writes (alleen met --apply): zusterrepos naast deze map, `~/.claude/settings.json`
#         (via de plugin-installer), `~/.kube/config-*.yaml`, `~/.kube/config`
#         (+ `.bak`), en met --write-profile een blok in het shellprofiel.
# Idempotent: ja — een tweede run kloont niets opnieuw, voegt geen dubbele
#         deny-regels toe en herschrijft het profielblok niet. Kubeconfigs
#         worden wél verse gegenereerd; die verlopen na 24 uur.
# Requires: git, uv, jq, kubectl, base64. `claude` voor de plugins.
#         Leestoegang tot de private repos (`gh auth login` of een PAT in de
#         credential store).
#
# Env (alle optioneel):
#   EMK_KUBECONFIG      pad naar het EMK service-account. Zonder deze var zoekt
#                       het script `~/.kube/emk-sa-*.y*ml`; bij meer dan één
#                       treffer stopt het en vraagt om deze var.
#   GARDENER_NAMESPACE  Gardener-projectnamespace (default garden-wh2mnkj)
#   SHOOTS              ruimte-gescheiden clusternamen
#   DEFAULT_SHOOT       welk cluster naar ~/.kube/config gaat
#   KUBE_DIR            default ~/.kube
#   KUBECONFIG_TTL      geldigheid in seconden (default 86400 — 24 uur)
#   ROOT                map waar de zusterrepos komen (default naast hub)
#   PROFILE_FILE        shellprofiel voor --write-profile (default ~/.bashrc)
#
# Usage:
#   ./scripts/onboard.sh                          # rapporteer, wijzig niets
#   ./scripts/onboard.sh --apply                  # voer uit
#   ./scripts/onboard.sh --apply --write-profile  # ook de env-vars vastzetten
#   ./scripts/onboard.sh --only kubeconfig --apply # alleen opnieuw inloggen
#   ./scripts/onboard.sh --self-test              # fixtures, geen netwerk
#   ./scripts/onboard.sh --version
#
# Exitcodes: 0 = klaar (of niets te doen), 1 = een stap faalde,
#            2 = verkeerd gebruik of een ontbrekende voorwaarde
#
# Style-afwijking: `#!/usr/bin/env bash` voor machines waar bash niet in /bin
# staat; consistent met de rest van de fleet.

set -euo pipefail

readonly ONBOARD_VERSION="0.1.0"

HUB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly HUB_DIR
readonly ROOT_DIR="${ROOT:-$(cd "${HUB_DIR}/.." && pwd)}"
readonly KUBE_DIR="${KUBE_DIR:-${HOME}/.kube}"
readonly GARDENER_NAMESPACE="${GARDENER_NAMESPACE:-garden-wh2mnkj}"
readonly SHOOTS="${SHOOTS:-test-accept conductionprod con-prod}"
readonly DEFAULT_SHOOT="${DEFAULT_SHOOT:-con-prod}"
readonly KUBECONFIG_TTL="${KUBECONFIG_TTL:-86400}"
readonly PROFILE_FILE="${PROFILE_FILE:-${HOME}/.bashrc}"
readonly PLUGINS_DIR="${ROOT_DIR}/claude-plugins"
readonly PROFILE_MARKER="# >>> conduction onboarding >>>"

APPLY=false
WRITE_PROFILE=false
ONLY=""
failures=0

# --- uitvoer ---------------------------------------------------------------

step() {
  echo
  echo "── $* ──"
}

ok() { echo "  ✓ $*"; }
skip() { echo "  - $*"; }
warn() { echo "  ! $*" >&2; }

fail() {
  echo "  ✗ $*" >&2
  failures=$((failures + 1))
}

die() {
  echo "fout: $*" >&2
  exit 2
}

# Zou-doen versus doet. Elke muterende stap gaat hierlangs, zodat een run
# zonder --apply gegarandeerd niets wijzigt.
would() {
  if [[ "${APPLY}" == true ]]; then
    return 1
  fi
  echo "  → zou doen: $*"
  return 0
}

want() {
  [[ -z "${ONLY}" || "${ONLY}" == "$1" ]]
}

# --- argumenten ------------------------------------------------------------

parse_args() {
  while (($# > 0)); do
    case "$1" in
      --apply) APPLY=true; shift ;;
      --write-profile) WRITE_PROFILE=true; shift ;;
      --only)
        [[ -n "${2:-}" ]] || die "--only vraagt een stap: prereqs, emk, fleet, plugins, settings, kubeconfig, verify"
        ONLY="$2"; shift 2 ;;
      --self-test) shift; self_test; exit $? ;;
      --version) echo "onboard.sh ${ONBOARD_VERSION}"; exit 0 ;;
      -h | --help) sed -n '4,80p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
      *) die "onbekend argument: $1" ;;
    esac
  done
}

# --- stap 1: voorwaarden ---------------------------------------------------

check_prereqs() {
  want prereqs || return 0
  step "Voorwaarden"
  local tool missing=0
  for tool in git uv jq kubectl base64; do
    if command -v "${tool}" >/dev/null 2>&1; then
      ok "${tool}"
    else
      fail "${tool} ontbreekt"
      missing=1
    fi
  done
  if command -v claude >/dev/null 2>&1; then
    ok "claude ($(claude --version 2>/dev/null | head -1))"
  else
    warn "claude niet op PATH — de plugin-stappen worden overgeslagen"
  fi
  # Leestoegang tot een private repo is de stap die stil faalt: git vraagt om
  # een wachtwoord dat niemand intypt, en de clone hangt of breekt af.
  if git ls-remote --exit-code https://github.com/ConductionNL/claude-plugins.git \
    HEAD >/dev/null 2>&1; then
    ok "leestoegang tot de private repos"
  else
    fail "geen leestoegang tot ConductionNL/claude-plugins — draai 'gh auth login' of zet een PAT in je credential store"
    missing=1
  fi
  ((missing == 0))
}

# --- stap 2: het EMK service-account ---------------------------------------

# Zoekt het service-account-kubeconfig. Eén treffer is de normale situatie:
# per persoon is er één. Meerdere treffers vragen een keuze — dan raden is
# precies hoe je met het account van een ex-collega gaat werken.
find_emk() {
  local dir="$1" explicit="${2:-}"
  local -a matches=()
  if [[ -n "${explicit}" ]]; then
    [[ -r "${explicit}" ]] || return 1
    echo "${explicit}"
    return 0
  fi
  # Haakjes zijn hier niet cosmetisch: `-name a -o -name b -print0` bindt de
  # -print0 alleen aan de laatste tak, dus zonder groepering verdwijnen de
  # .yml-treffers stil. De zelftest ving dat.
  while IFS= read -r -d '' f; do
    matches+=("${f}")
  done < <(find "${dir}" -maxdepth 1 \( -name 'emk-sa-*.yml' -o -name 'emk-sa-*.yaml' \) -print0 2>/dev/null || true)
  case "${#matches[@]}" in
    1) echo "${matches[0]}"; return 0 ;;
    0) return 1 ;;          # niets gevonden
    *) return 2 ;;          # meer dan één: de aanroeper moet kiezen
  esac
}

EMK_FILE=""

check_emk() {
  want emk || return 0
  step "EMK service-account"
  local found rc=0
  found="$(find_emk "${KUBE_DIR}" "${EMK_KUBECONFIG:-}")" || rc=$?
  if [[ -n "${found}" ]]; then
    EMK_FILE="${found}"
    ok "gevonden: $(basename "${EMK_FILE}")"
    return 0
  fi
  if ((rc > 1)); then
    fail "meer dan één emk-sa-bestand in ${KUBE_DIR} — zet EMK_KUBECONFIG naar het juiste"
  else
    fail "geen emk-sa-*.yml in ${KUBE_DIR}"
    echo "     Dit is de enige stap die je met de hand moet regelen: vraag een EMK" >&2
    echo "     service-account-kubeconfig aan bij Fuga Cloud en zet het in ${KUBE_DIR}." >&2
    echo "     Zie claude-plugins/docs/toolchain-runbook.md § Laag 1." >&2
  fi
  return 1
}

# --- stap 3: de fleet ------------------------------------------------------

setup_fleet() {
  want fleet || return 0
  step "Fleet en werkkopieën"
  if would "clone_all.sh draaien in ${ROOT_DIR}"; then
    :
  else
    ROOT="${ROOT_DIR}" "${HUB_DIR}/scripts/clone_all.sh" 2>&1 | sed 's/^/  /' \
      || fail "clone_all.sh faalde"
  fi
  if [[ -d "${HUB_DIR}/.venv" ]]; then
    ok "hub: uv-omgeving bestaat al"
  elif would "uv sync in ${HUB_DIR}"; then
    :
  else
    if (cd "${HUB_DIR}" && uv sync --quiet); then
      ok "hub: uv sync"
    else
      fail "uv sync faalde"
    fi
  fi
}

# --- stap 4: de plugins ----------------------------------------------------

setup_plugins() {
  want plugins || return 0
  step "Agent-plugins"
  command -v claude >/dev/null 2>&1 || { skip "claude niet op PATH"; return 0; }

  if would "marketplace toevoegen en beide plugins installeren"; then
    return 0
  fi

  if claude plugin marketplace add ConductionNL/claude-plugins >/dev/null 2>&1; then
    ok "marketplace toegevoegd"
  else
    warn "marketplace toevoegen faalde of stond er al"
  fi

  # Twee losse aanroepen. `claude plugin install a b` installeert stil alleen
  # de eerste en meldt niets over de tweede.
  local p
  for p in engineering-baseline conduction-platform; do
    if claude plugin install "${p}" >/dev/null 2>&1; then
      ok "geïnstalleerd: ${p}"
    else
      warn "installeren van ${p} faalde of stond er al"
    fi
  done
}

# --- stap 5: de deny-laag --------------------------------------------------

setup_settings() {
  want settings || return 0
  step "Deny-laag en proza-kern"
  local installer="${PLUGINS_DIR}/scripts/install-settings.sh"
  if [[ ! -x "${installer}" ]]; then
    fail "${installer} niet gevonden — is claude-plugins gekloond?"
    return 1
  fi
  if would "install-settings.sh --profile conduction --claude-md --apply"; then
    "${installer}" --profile conduction 2>&1 | sed 's/^/  /' || true
    return 0
  fi
  if "${installer}" --profile conduction --claude-md --apply 2>&1 | sed 's/^/  /'; then
    ok "deny-laag en CLAUDE.md-kern geregeld"
  else
    fail "install-settings.sh faalde"
  fi
}

# --- stap 6: env-vars ------------------------------------------------------

profile_block() {
  cat <<EOF
${PROFILE_MARKER}
export CONDUCTION_HUB="${HUB_DIR}"
export CLAUDE_GUARDRAIL_CONFIG="${PLUGINS_DIR}/plugins/conduction-platform/config/guardrail.conf"
# <<< conduction onboarding <<<
EOF
}

setup_env() {
  want env || return 0
  step "Omgevingsvariabelen"
  if [[ "${WRITE_PROFILE}" != true ]]; then
    echo "  Zet deze in je shellprofiel (of draai met --write-profile):"
    profile_block | sed 's/^/    /'
    return 0
  fi
  if grep -qF "${PROFILE_MARKER}" "${PROFILE_FILE}" 2>/dev/null; then
    ok "profielblok staat al in ${PROFILE_FILE}"
    return 0
  fi
  if would "het profielblok toevoegen aan ${PROFILE_FILE}"; then
    return 0
  fi
  printf '\n%s\n' "$(profile_block)" >> "${PROFILE_FILE}"
  ok "profielblok toegevoegd aan ${PROFILE_FILE}"
}

# --- stap 7: kubeconfigs ---------------------------------------------------

# Één Gardener-API-aanroep per cluster. Schrijft naar een tmp-bestand en
# verplaatst pas bij succes: anders verlies je je geldige kubeconfig aan een
# mislukte aanroep.
generate_kubeconfig() {
  local shoot="$1" target="$2" tmp
  tmp="$(mktemp "${target}.XXXXXX")"
  if kubectl --kubeconfig "${EMK_FILE}" create --raw \
    "/apis/core.gardener.cloud/v1beta1/namespaces/${GARDENER_NAMESPACE}/shoots/${shoot}/adminkubeconfig" \
    -f - <<< "{\"spec\":{\"expirationSeconds\":${KUBECONFIG_TTL}}}" 2>/dev/null |
    jq -r '.status.kubeconfig' | base64 -d > "${tmp}" 2>/dev/null &&
    [[ -s "${tmp}" ]]; then
    chmod 600 "${tmp}"
    mv "${tmp}" "${target}"
    return 0
  fi
  rm -f "${tmp}"
  return 1
}

setup_kubeconfig() {
  want kubeconfig || return 0
  step "Cluster-kubeconfigs (geldig ${KUBECONFIG_TTL}s)"
  [[ -n "${EMK_FILE}" ]] || { fail "geen EMK service-account — stap emk eerst"; return 1; }

  local shoot target default_target=""
  local suffix="${GARDENER_NAMESPACE#garden-}"
  for shoot in ${SHOOTS}; do
    target="${KUBE_DIR}/config-${suffix}-${shoot}.yaml"
    [[ "${shoot}" == "${DEFAULT_SHOOT}" ]] && default_target="${target}"
    if would "kubeconfig genereren voor ${shoot} → ${target}"; then
      continue
    fi
    if generate_kubeconfig "${shoot}" "${target}"; then
      ok "${shoot} → $(basename "${target}")"
    else
      fail "${shoot}: genereren faalde (service-account geldig? cluster bestaat?)"
    fi
  done

  # De kale `kubectl` moet op het standaardcluster uitkomen.
  if [[ -z "${default_target}" ]]; then
    warn "DEFAULT_SHOOT '${DEFAULT_SHOOT}' staat niet in SHOOTS — niets gekopieerd naar ${KUBE_DIR}/config"
    return 0
  fi
  if would "${DEFAULT_SHOOT} kopiëren naar ${KUBE_DIR}/config (met back-up)"; then
    return 0
  fi
  [[ -f "${default_target}" ]] || { fail "geen ${default_target} om te kopiëren"; return 1; }
  if [[ -f "${KUBE_DIR}/config" ]]; then
    cp -p "${KUBE_DIR}/config" "${KUBE_DIR}/config.bak"
    ok "back-up: ${KUBE_DIR}/config.bak"
  fi
  install -m 600 "${default_target}" "${KUBE_DIR}/config"
  ok "${DEFAULT_SHOOT} staat op ${KUBE_DIR}/config"
}

# --- stap 8: verifiëren ----------------------------------------------------

verify() {
  want verify || return 0
  step "Verificatie"

  if [[ "${APPLY}" != true ]]; then
    skip "niets uitgevoerd, dus niets te verifiëren"
    return 0
  fi

  if (cd "${HUB_DIR}" && uv run python -c \
    'from docs_mcp import content; assert content.fetch_import_list()' >/dev/null 2>&1); then
    ok "handboek-MCP levert een componentlijst"
  else
    fail "handboek-MCP geeft geen componenten"
  fi

  if command -v claude >/dev/null 2>&1; then
    local installed
    installed="$(claude plugin list 2>/dev/null | grep -c '@conduction' || true)"
    if [[ "${installed}" == "2" ]]; then
      ok "beide plugins geïnstalleerd"
    else
      fail "${installed} van 2 plugins geïnstalleerd — 'claude plugin install' neemt één naam per aanroep"
    fi
  fi

  if [[ -x "${PLUGINS_DIR}/plugins/engineering-baseline/scripts/check-guardrails.sh" ]]; then
    if "${PLUGINS_DIR}/plugins/engineering-baseline/scripts/check-guardrails.sh" >/dev/null 2>&1; then
      ok "guardrails staan in settings.json"
    else
      warn "check-guardrails.sh meldt bevindingen — draai hem los voor details"
    fi
  fi

  if kubectl --request-timeout=10s version --short >/dev/null 2>&1; then
    ok "kubectl bereikt het standaardcluster"
  else
    warn "kubectl bereikt het cluster niet — netwerk, of het service-account is verlopen"
  fi
}

# --- zelftest --------------------------------------------------------------
# Alleen de pure logica: geen netwerk, geen cluster, geen wijzigingen aan de
# echte omgeving. Wat overblijft is precies wat zonder cluster te toetsen is.
self_test() {
  local tmp
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN
  local -i pass=0 fail=0

  check() {
    if [[ "$2" == "$3" ]]; then
      pass+=1
    else
      fail+=1
      echo "  FAIL $1: verwacht '$3', kreeg '$2'" >&2
    fi
  }

  # EMK-detectie: nul, één, twee bestanden, en een expliciete override.
  mkdir -p "${tmp}/leeg"
  local got rc
  got="$(find_emk "${tmp}/leeg" || true)"
  check "geen bestand geeft niets" "${got}" ""

  mkdir -p "${tmp}/een"
  : > "${tmp}/een/emk-sa-wh2mnkj_iemand-conduction.yml"
  got="$(find_emk "${tmp}/een" || true)"
  check "één bestand wordt gevonden" "$(basename "${got}")" "emk-sa-wh2mnkj_iemand-conduction.yml"

  mkdir -p "${tmp}/twee"
  : > "${tmp}/twee/emk-sa-a.yml"
  : > "${tmp}/twee/emk-sa-b.yml"
  rc=0
  got="$(find_emk "${tmp}/twee")" || rc=$?
  check "twee bestanden is geen keuze" "${rc}" "2"

  : > "${tmp}/expliciet.yml"
  got="$(find_emk "${tmp}/twee" "${tmp}/expliciet.yml" || true)"
  check "expliciet pad wint" "${got}" "${tmp}/expliciet.yml"

  # would(): zonder --apply mag geen enkele muterende stap doorlopen.
  APPLY=false
  if would "iets" >/dev/null; then pass+=1; else fail+=1; echo "  FAIL would() laat door zonder --apply" >&2; fi
  APPLY=true
  if would "iets" >/dev/null; then fail+=1; echo "  FAIL would() blokkeert mét --apply" >&2; else pass+=1; fi
  APPLY=false

  # --only filtert.
  ONLY="kubeconfig"
  if want kubeconfig; then pass+=1; else fail+=1; echo "  FAIL want() weigert de gekozen stap" >&2; fi
  if want fleet; then fail+=1; echo "  FAIL want() laat een niet-gekozen stap door" >&2; else pass+=1; fi
  ONLY=""

  # Het profielblok is idempotent te herkennen.
  profile_block > "${tmp}/profile"
  if grep -qF "${PROFILE_MARKER}" "${tmp}/profile"; then pass+=1; else fail+=1; echo "  FAIL profielblok mist de marker" >&2; fi

  echo "zelftest: ${pass} geslaagd, ${fail} gefaald"
  ((fail == 0))
}

# --- hoofdprogramma --------------------------------------------------------

main() {
  parse_args "$@"

  echo "Conduction-werkplek inrichten"
  echo "  hub:      ${HUB_DIR}"
  echo "  fleet:    ${ROOT_DIR}"
  echo "  modus:    $([[ "${APPLY}" == true ]] && echo "UITVOEREN" || echo "alleen rapporteren (gebruik --apply)")"

  check_prereqs || true
  check_emk || true
  setup_fleet
  setup_plugins
  setup_settings
  setup_env
  setup_kubeconfig
  verify

  echo
  if ((failures == 0)); then
    if [[ "${APPLY}" == true ]]; then
      echo "onboarding: klaar. Herstart Claude Code zodat de plugins laden."
    else
      echo "onboarding: niets gewijzigd. Draai opnieuw met --apply."
    fi
    return 0
  fi
  echo "onboarding: ${failures} stap(pen) faalden — zie hierboven." >&2
  return 1
}

main "$@"
