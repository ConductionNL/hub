#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# role: tool
#
# scripts/rollout_frontend_image_tls.sh — rolt de frontend-image-pin, de
# tenant-validatie en de BYO-certificaattest uit, van begin tot eind.
#
# Trunk-based: het werk staat op `main` in Nextcloud-base en react-base. Geen
# branches, geen PR's. Het script zaait het secret, pusht beide repo's, wacht op
# Argo en verifieert daarna op het cluster.
#
# De VOLGORDE is bindend, en dat is de reden dat dit een script is en geen
# lijstje:
#
#   * react-base maakt de per-tenant image-pin bindend. Landt dat op de remote
#     vóór de drift-uitlijning in Nextcloud-base, dan rolt Argo acht tenants
#     terug naar `latest`/`dev`, waarvan drie in productie.
#   * Het TLS-secret moet bestaan vóór de tenant-wijziging, anders serveert
#     canary.accept.openwoo.app even geen bruikbaar cert.
#
# Elke stap is idempotent: al gepusht, secret al aanwezig of al gesynct levert
# een melding op en geen fout. Draai gerust opnieuw.
#
# Stap 5 is een echte toets, geen rapportage: hij faalt met exitcode 1 als een
# verwachting niet uitkomt.
#
# Writes: cluster (één TLS-secret in namespace canary-accept), en `git push
#         origin main` in twee repo's. Stap 2 schrijft tijdelijk sleutelmateriaal
#         naar een mktemp-map met 0700 en shredt die daarna.
# Idempotent: ja, per stap
# Requires: bash, git, kubectl, openssl, yq, go
#
# Usage:
#   ./rollout_frontend_image_tls.sh status     # waar staan we, wijzigt niets
#   ./rollout_frontend_image_tls.sh all        # alles, met bevestiging per stap
#   ./rollout_frontend_image_tls.sh all --yes  # alles, zonder vragen
#   ./rollout_frontend_image_tls.sh 4          # één stap
#   ./rollout_frontend_image_tls.sh rollback   # canary-proeven terugdraaien
#
# Stappen:
#   1  preflight   tooling, cluster, main-stand, verify.sh in beide repo's
#   2  secret      canary-selfsigned-tls zaaien in namespace canary-accept
#   3  push-nb     Nextcloud-base naar origin/main + wachten tot Argo synct
#   4  push-rb     react-base naar origin/main + wachten tot Argo synct
#   5  verify      harde toets op het cluster (faalt met exitcode 1)
#
# Crontab: niet plannen. Dit is een eenmalige uitrol met een mens erbij.

set -euo pipefail

HUB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly HUB_DIR
readonly NB_DIR="${HUB_DIR}/../Nextcloud-base"
readonly RB_DIR="${HUB_DIR}/../react-base"

readonly TENANT_NS="canary-accept"
readonly TENANT_FILE="nextcloud-platform/values/tenants/tenant-canary-accept.yaml"
readonly ARGO_APP="canary-accept-reactfront"
readonly TLS_SECRET="canary-selfsigned-tls"
readonly TLS_HOST="canary.accept.openwoo.app"

# Hoe lang wachten tot Argo een push heeft opgepikt. De git-generator van de
# ApplicationSet pollt standaard elke ~3 minuten, dus 10 minuten is ruim.
# Env-tunable: een trage sync is geen reden om het script te moeten patchen.
readonly ARGO_WAIT_SECONDS="${ARGO_WAIT_SECONDS:-600}"
readonly ARGO_POLL_SECONDS="${ARGO_POLL_SECONDS:-15}"

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

ASSUME_YES=0
FAILURES=0

# "${1:-}" en niet "$1": `info` zonder argument is een lege regel, en met
# `set -u` zou een kale $1 daarop struikelen.
info() { printf '%s\n' "${1:-}"; }
ok() { printf "${GREEN}OK${NC} %s\n" "$1"; }
warn() { printf "${YELLOW}LET OP${NC} %s\n" "$1" >&2; }
fail() { printf "${RED}FOUT${NC} %s\n" "$1" >&2; exit 1; }

# Toets die niet meteen afbreekt: alle verwachtingen worden gemeten, daarna
# bepaalt het totaal de exitcode. Anders zie je bij een uitrol alleen de eerste
# afwijking en moet je vijf keer opnieuw draaien.
check() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    ok "${label}: ${actual}"
  else
    printf "${RED}FOUT${NC} %s\n  verwacht: %s\n  gekregen: %s\n" \
      "$label" "$expected" "${actual:-<leeg>}" >&2
    FAILURES=$((FAILURES + 1))
  fi
}

banner() {
  echo
  echo "=============================================================="
  echo "$1"
  echo "=============================================================="
}

confirm() {
  local answer
  [[ "$ASSUME_YES" -eq 1 ]] && return 0
  # Zonder TTY levert `read` meteen een lege regel op en zou elke vraag
  # stilzwijgend "nee" worden. main() vangt dat vooraf af; dit is de vangnet.
  [[ -t 0 ]] || fail "geen TTY om '$1' te beantwoorden — draai met --yes"
  read -r -p "$1 [j/N] " answer
  [[ "$answer" == "j" || "$answer" == "J" ]]
}

commits_ahead() {
  git -C "$1" rev-list --count origin/main..main 2>/dev/null || echo "?"
}

is_pushed() {
  [[ "$(commits_ahead "$1")" == "0" ]]
}

# De verwachte image komt uit het tenant-bestand zelf, niet uit een constante
# hier — anders lopen script en werkelijkheid uiteen zodra iemand de proef bijstelt.
expected_image() {
  local reg repo tag
  reg="$(yq eval '.tenant.frontend.registry // ""' "${NB_DIR}/${TENANT_FILE}")"
  repo="$(yq eval '.tenant.frontend.repository // ""' "${NB_DIR}/${TENANT_FILE}")"
  tag="$(yq eval '.tenant.frontend.tag // ""' "${NB_DIR}/${TENANT_FILE}")"
  [[ -n "$repo" && -n "$tag" ]] || return 1
  if [[ -n "$reg" ]]; then
    printf '%s/%s:%s\n' "$reg" "$repo" "$tag"
  else
    printf '%s:%s\n' "$repo" "$tag"
  fi
}

expected_tls_secret() {
  yq eval '.tenant.frontend.tls.secretName // ""' "${NB_DIR}/${TENANT_FILE}"
}

assert_clean_main() {
  local dir="$1" label="$2" branch dirty
  branch="$(git -C "$dir" branch --show-current)"
  [[ "$branch" == "main" ]] || fail "${label} staat op '${branch}', niet op main"

  # Untracked rommel telt niet mee; ongecommitte wijzigingen aan gevolgde
  # bestanden wel — die zouden anders stilletjes buiten de push vallen.
  dirty="$(git -C "$dir" status --porcelain --untracked-files=no)"
  if [[ -n "$dirty" ]]; then
    printf '%s\n' "$dirty" | sed 's/^/  /' >&2
    fail "${label} heeft ongecommitte wijzigingen — commit ze of zet ze weg"
  fi
  ok "${label}: main, schoon, $(commits_ahead "$dir") commit(s) vóór origin/main"
}

# Draai verify.sh; toon de uitvoer alleen als hij faalt. Beide repo's schrijven
# bestaande waarschuwingen naar stderr en die verzuipen anders het echte signaal.
run_verify() {
  local dir="$1" label="$2" out
  out="$(mktemp)"
  info "verify.sh in ${label}..."
  if (cd "$dir" && ./scripts/verify.sh) >"$out" 2>&1; then
    ok "${label} verify groen"
    rm -f "$out"
  else
    sed 's/^/  /' "$out" >&2
    rm -f "$out"
    fail "verify.sh faalt in ${label} — niets gepusht"
  fi
}

push_main() {
  local dir="$1" label="$2"

  if is_pushed "$dir"; then
    ok "${label}: main staat al op de remote"
    return 0
  fi

  info
  info "${label} heeft $(commits_ahead "$dir") commit(s) klaar:"
  git -C "$dir" log --oneline origin/main..main | sed 's/^/  /'
  info

  confirm "Push ${label} naar origin/main?" || fail "afgebroken door gebruiker"

  # Geen --force in welke vorm dan ook. Een afwijzing heeft twee heel
  # verschillende oorzaken en die niet uit elkaar houden stuurt je de verkeerde
  # kant op: `pull --rebase` helpt niets tegen een branch-ruleset.
  local out rc
  out="$(mktemp)"
  set +e
  git -C "$dir" push origin main >"$out" 2>&1
  rc=$?
  set -e
  cat "$out"

  if [[ $rc -eq 0 ]]; then
    rm -f "$out"
    ok "${label} gepusht naar origin/main"
    return 0
  fi

  if grep -qE 'GH013|repository rule violations|protected branch|must be made through a pull request' "$out"; then
    rm -f "$out"
    fail "${label}: GitHub weigert een directe push naar main — er staat een branch-ruleset op (pull request en/of verplichte checks). Trunk-based werkt hier niet zonder die regel aan te passen. Kies: een PR openen, of de ruleset aanpassen in de repo-instellingen. Dat laatste is een bewuste beveiligingskeuze; dit script doet dat niet voor je."
  fi

  if grep -qE 'non-fast-forward|fetch first|behind its remote' "$out"; then
    rm -f "$out"
    fail "${label}: origin/main is verderop. Doe 'git -C ${dir} pull --rebase origin main', controleer het resultaat en draai deze stap opnieuw."
  fi

  rm -f "$out"
  fail "${label}: push afgewezen, zie de uitvoer hierboven"
}

# Wacht tot de ApplicationSet de nieuwe tenant-inhoud heeft opgepikt EN de
# Application Synced/Healthy is.
#
# Alleen op Synced/Healthy wachten is te weinig: de Application stond al
# Synced/Healthy met de OUDE inhoud, dus de wachtlus keerde meteen terug en
# stap 5 mat een cluster dat nog niets van de push had gezien. De git-generator
# van de ApplicationSet pollt los van de Application-sync, dus we wachten eerst
# tot een verwachte string in de gerenderde values staat.
#
# $1 = tekst die in spec.sources[0].helm.values moet verschijnen (leeg = alleen
#      op sync/health wachten)
wait_for_argo() {
  local needle="${1:-}"
  local deadline=$((SECONDS + ARGO_WAIT_SECONDS))
  local sync health values seen=0

  if [[ -n "$needle" ]]; then
    info "Wachten tot de ApplicationSet '${needle}' rendert (max ${ARGO_WAIT_SECONDS}s)..."
  fi

  while ((SECONDS < deadline)); do
    if [[ -n "$needle" && "$seen" -eq 0 ]]; then
      values="$(kubectl -n argocd get application "$ARGO_APP" \
        -o jsonpath='{.spec.sources[0].helm.values}' 2>/dev/null || echo '')"
      if [[ "$values" == *"$needle"* ]]; then
        seen=1
        ok "ApplicationSet heeft de nieuwe tenant-inhoud opgepikt"
      else
        printf '  generator nog op de oude inhoud ... \r'
        sleep "$ARGO_POLL_SECONDS"
        continue
      fi
    fi

    sync="$(kubectl -n argocd get application "$ARGO_APP" \
      -o jsonpath='{.status.sync.status}' 2>/dev/null || echo '')"
    health="$(kubectl -n argocd get application "$ARGO_APP" \
      -o jsonpath='{.status.health.status}' 2>/dev/null || echo '')"
    if [[ "$sync" == "Synced" && "$health" == "Healthy" ]]; then
      ok "Argo: Synced/Healthy"
      return 0
    fi
    printf '  %s/%s ... \r' "${sync:-?}" "${health:-?}"
    sleep "$ARGO_POLL_SECONDS"
  done

  info
  if [[ -n "$needle" && "$seen" -eq 0 ]]; then
    warn "De ApplicationSet rendert '${needle}' na ${ARGO_WAIT_SECONDS}s nog niet."
    warn "De git-generator pollt traag; verhoog ARGO_WAIT_SECONDS of draai stap 5 straks."
  else
    warn "Argo is na ${ARGO_WAIT_SECONDS}s nog ${sync:-?}/${health:-?}."
  fi
  return 0
}

# --------------------------------------------------------------------------
step_1_preflight() {
  banner "Stap 1 — preflight"

  local tool
  for tool in git kubectl openssl yq go; do
    command -v "$tool" >/dev/null || fail "${tool} ontbreekt"
  done
  ok "tooling compleet"

  kubectl get ns "$TENANT_NS" >/dev/null 2>&1 || fail "namespace ${TENANT_NS} niet bereikbaar"
  ok "cluster bereikbaar (context: $(kubectl config current-context))"

  git -C "$NB_DIR" fetch -q origin main
  git -C "$RB_DIR" fetch -q origin main
  ok "origin/main opgehaald"

  assert_clean_main "$NB_DIR" "Nextcloud-base"
  assert_clean_main "$RB_DIR" "react-base"

  expected_image >/dev/null \
    || fail "${TENANT_FILE} pint geen repository+tag — de proef zou niets bewijzen"
  ok "canary pint $(expected_image)"

  run_verify "$NB_DIR" "Nextcloud-base"
  run_verify "$RB_DIR" "react-base"
}

# --------------------------------------------------------------------------
step_2_secret() {
  banner "Stap 2 — TLS-secret zaaien"

  if kubectl -n "$TENANT_NS" get secret "$TLS_SECRET" >/dev/null 2>&1; then
    ok "secret ${TLS_SECRET} bestaat al"
    kubectl -n "$TENANT_NS" get secret "$TLS_SECRET" \
      -o jsonpath='{.data.tls\.crt}' | base64 -d \
      | openssl x509 -noout -subject -issuer -dates | sed 's/^/  /'
    info
    info "Vervangen? kubectl -n ${TENANT_NS} delete secret ${TLS_SECRET}"
    return 0
  fi

  info "Self-signed cert voor ${TLS_HOST}, 90 dagen geldig."
  info "Browsers waarschuwen daarop — bij deze proef is dat het verwachte gedrag."
  confirm "Doorgaan?" || fail "afgebroken door gebruiker"

  local tmp
  tmp="$(mktemp -d)"
  chmod 700 "$tmp"
  # shellcheck disable=SC2064  # tmp nu uitvouwen, niet bij trap-uitvoering
  trap "shred -u '${tmp}'/* 2>/dev/null || true; rm -rf '${tmp}'" EXIT

  openssl req -x509 -newkey rsa:2048 -sha256 -days 90 -nodes \
    -keyout "${tmp}/tls.key" -out "${tmp}/tls.crt" \
    -subj "/CN=${TLS_HOST}" \
    -addext "subjectAltName=DNS:${TLS_HOST}" 2>/dev/null \
    || fail "openssl kon geen cert maken"

  kubectl -n "$TENANT_NS" create secret tls "$TLS_SECRET" \
    --cert="${tmp}/tls.crt" --key="${tmp}/tls.key" \
    || fail "kon secret niet aanmaken"

  ok "secret ${TLS_SECRET} gezaaid (sleutelmateriaal geshred)"
}

# --------------------------------------------------------------------------
step_3_push_nb() {
  banner "Stap 3 — Nextcloud-base naar de remote"
  info "Bevat: frontend-validatie, tag-drift op 8 tenants, thema-checks, de"
  info "fixture-testsuite, en beide canary-proeven (image-pin + BYO-cert)."
  info "Moet vóór stap 4 landen, anders rolt Argo acht tenants terug."

  kubectl -n "$TENANT_NS" get secret "$TLS_SECRET" >/dev/null 2>&1 \
    || fail "secret ${TLS_SECRET} ontbreekt — draai stap 2, anders serveert ${TLS_HOST} even geen bruikbaar cert"
  ok "TLS-secret aanwezig"

  run_verify "$NB_DIR" "Nextcloud-base"
  push_main "$NB_DIR" "Nextcloud-base"
  # Wacht op het TLS-secret uit het tenant-bestand: dát is het eerste stukje
  # nieuwe inhoud dat de generator moet renderen.
  wait_for_argo "$(expected_tls_secret)"
}

# --------------------------------------------------------------------------
step_4_push_rb() {
  banner "Stap 4 — react-base naar de remote"

  git -C "$NB_DIR" fetch -q origin main
  is_pushed "$NB_DIR" || fail "Nextcloud-base staat nog niet op de remote — doe stap 3 eerst"
  ok "Nextcloud-base staat op de remote"

  info "Bevat: registry/repository als eigen velden, en de per-tenant"
  info "voorwaardelijke ignoreDifferences via templatePatch."

  run_verify "$RB_DIR" "react-base"
  push_main "$RB_DIR" "react-base"
  # react-base wijzigt de ApplicationSet zelf; de image-pin is dan het bewijs
  # dat de nieuwe template is toegepast.
  wait_for_argo "$(yq eval '.tenant.frontend.tag' "${NB_DIR}/${TENANT_FILE}")"
}

# --------------------------------------------------------------------------
step_5_verify() {
  banner "Stap 5 — harde toets op het cluster"
  FAILURES=0

  local want_image want_secret
  want_image="$(expected_image)" || fail "kan de verwachte image niet afleiden"
  want_secret="$(expected_tls_secret)"

  # 1. Landt de image-pin uit git op de bestaande Deployment?
  check "draaiende image" "$want_image" \
    "$(kubectl -n "$TENANT_NS" get deploy woo-website \
        -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo '')"

  # 2. Verwijst de Ingress naar het gezaaide secret?
  check "ingress TLS-secret" "$want_secret" \
    "$(kubectl -n "$TENANT_NS" get ingress woo-website \
        -o jsonpath='{.spec.tls[0].secretName}' 2>/dev/null || echo '')"

  # 3. De kern van de none-tak: er hoort GEEN cert-manager-annotatie te staan.
  check "cert-manager-annotatie (hoort leeg)" "" \
    "$(kubectl -n "$TENANT_NS" get ingress woo-website \
        -o jsonpath='{.metadata.annotations.cert-manager\.io/cluster-issuer}' 2>/dev/null || echo '')"

  # 4. Serveert de host werkelijk óns cert? Niet wat in het secret staat, maar
  #    wat er over de lijn komt — dat is het enige dat een bezoeker merkt.
  local subject issuer
  subject="$(echo | timeout 10 openssl s_client -connect "${TLS_HOST}:443" \
    -servername "$TLS_HOST" 2>/dev/null | openssl x509 -noout -subject 2>/dev/null \
    | sed 's/^subject=//; s/^ *//' || echo '')"
  issuer="$(echo | timeout 10 openssl s_client -connect "${TLS_HOST}:443" \
    -servername "$TLS_HOST" 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null \
    | sed 's/^issuer=//; s/^ *//' || echo '')"
  check "geserveerd cert subject" "CN=${TLS_HOST}" "$subject"
  check "geserveerd cert is self-signed (issuer==subject)" "$subject" "$issuer"

  # 5. De ignore-diff op de image hoort voor deze tenant weg te zijn — anders
  #    landde de pin toevallig en niet doordat Argo hem reconcilieert.
  local ignore_json
  ignore_json="$(kubectl -n argocd get application "$ARGO_APP" \
    -o jsonpath='{.spec.ignoreDifferences}' 2>/dev/null || echo '')"
  if [[ "$ignore_json" == *'containers[].image'* ]]; then
    printf "${RED}FOUT${NC} %s\n" \
      "ignoreDifferences bevat nog containers[].image — de pin is niet bindend" >&2
    FAILURES=$((FAILURES + 1))
  else
    ok "ignoreDifferences: geen image-expressie meer voor deze tenant"
  fi

  # 6. Argo moet het ook eens zijn met zichzelf.
  check "Argo sync/health" "Synced/Healthy" \
    "$(kubectl -n argocd get application "$ARGO_APP" \
        -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || echo '')"

  info
  if [[ "$FAILURES" -eq 0 ]]; then
    ok "alle verwachtingen uitgekomen"
    info
    info "Beide proeven zijn bevestigd. Draai 'rollback' om ze uit canary te halen."
  else
    fail "${FAILURES} verwachting(en) niet uitgekomen"
  fi
}

# --------------------------------------------------------------------------
cmd_rollback() {
  banner "Rollback — canary-proeven uit het tenant-bestand"
  info "Haalt het hele tenant.frontend-blok uit ${TENANT_FILE}."
  info "De image valt dan terug op de platform-default en de Ingress op"
  info "wildcard-openwoo-tls. Het secret ${TLS_SECRET} blijft staan; verwijder"
  info "het los als je het niet meer wilt."
  info

  yq eval '.tenant.frontend' "${NB_DIR}/${TENANT_FILE}" | grep -q . 2>/dev/null \
    || { ok "geen frontend-blok meer — al teruggedraaid"; return 0; }

  confirm "Frontend-blok verwijderen en committen?" || fail "afgebroken door gebruiker"

  yq eval -i 'del(.tenant.frontend)' "${NB_DIR}/${TENANT_FILE}"
  run_verify "$NB_DIR" "Nextcloud-base"
  git -C "$NB_DIR" add "$TENANT_FILE"
  git -C "$NB_DIR" commit -q -m "test(canary): proeven teruggedraaid

Image-pin en BYO-certificaattak zijn bevestigd; het frontend-blok kan weg.
Canary valt terug op de platform-default image en wildcard-openwoo-tls."
  ok "teruggedraaid en gecommit"
  push_main "$NB_DIR" "Nextcloud-base"
}

# --------------------------------------------------------------------------
cmd_status() {
  banner "Stand van zaken"

  local pair dir label
  for pair in "${NB_DIR}:Nextcloud-base" "${RB_DIR}:react-base"; do
    dir="${pair%%:*}"
    label="${pair#*:}"
    printf '  %-16s branch=%-8s %s\n' "$label" \
      "$(git -C "$dir" branch --show-current 2>/dev/null)" \
      "$(is_pushed "$dir" && echo 'gelijk aan origin/main' || echo "$(commits_ahead "$dir") commit(s) te pushen")"
  done

  info
  if kubectl -n "$TENANT_NS" get secret "$TLS_SECRET" >/dev/null 2>&1; then
    ok "secret ${TLS_SECRET} aanwezig"
  else
    info "  secret ${TLS_SECRET}: nog niet gezaaid (stap 2)"
  fi

  info "  canary pint: $(expected_image 2>/dev/null || echo '<geen pin>')"
  printf '  argo %s: %s\n' "$ARGO_APP" \
    "$(kubectl -n argocd get application "$ARGO_APP" \
        -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || echo '?')"
}

usage() { sed -n '3,47p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

main() {
  local step="${1:-status}"
  shift || true
  local arg
  for arg in "$@"; do
    [[ "$arg" == "--yes" ]] && ASSUME_YES=1
  done

  # Stappen die iets muteren vragen om bevestiging. Zonder TTY kan dat niet, en
  # dan zou het script pas halverwege stuklopen op een vraag die niemand kan
  # beantwoorden. Vooraf stoppen, met de oplossing erbij.
  case "$step" in
    2|3|4|all|rollback)
      if [[ ! -t 0 ]] && [[ "$ASSUME_YES" -eq 0 ]]; then
        fail "geen interactieve shell — draai '${step} --yes', of start het script vanaf een terminal"
      fi
      ;;
  esac

  case "$step" in
    status) cmd_status ;;
    1) step_1_preflight ;;
    2) step_2_secret ;;
    3) step_3_push_nb ;;
    4) step_4_push_rb ;;
    5) step_5_verify ;;
    rollback) cmd_rollback ;;
    all)
      step_1_preflight
      step_2_secret
      step_3_push_nb
      step_4_push_rb
      step_5_verify
      ;;
    -h|--help) usage ;;
    *) fail "onbekende stap '${step}' — zie --help" ;;
  esac
}

main "$@"
