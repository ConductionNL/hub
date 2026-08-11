#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# role: tool
#
# scripts/swap_epe_cert.sh — zet het Sectigo-certificaat van gemeente Epe over
# naar namespace epe-prod en zet de tenant op `issuer: none`.
#
# Waarom dit moet: het CAA-record van epe.nl staat alleen digicert, certSIGN,
# kpn, entrust, sectigo en ssl.com toe. Let's Encrypt staat er NIET bij en kan
# er dus nooit uitgeven. `certificate/open-epe-nl-tls` in epe-prod bleef daarom
# retryen op een invalid order (403 urn:ietf:params:acme:error:caa) en
# open.epe.nl serveerde het fake-certificaat van de ingress.
#
# Het echte certificaat bestond al, in de OUDE namespace `epe`. Dit script
# kopieert dat secret onder de naam die het tenantbestand verwacht, merget de
# tenantwijziging op main, en ruimt daarna het lege Certificate op.
#
# De VOLGORDE is bindend:
#
#   * Het secret gaat als EERSTE. Dat mag vóór de merge, want cert-manager
#     schrijft alleen bij geslaagde uitgifte en CAA maakt slagen onmogelijk —
#     er is dus niets dat het geseede certificaat kan overschrijven. Zo staat
#     de site meteen weer op een geldig cert in plaats van na de Argo-sync.
#   * Het Certificate gaat als LAATSTE, ná de sync. Zolang de ingress nog de
#     annotatie `cert-manager.io/cluster-issuer` draagt, maakt de ingress-shim
#     een verwijderd Certificate binnen seconden terug.
#
# Elke stap is idempotent: secret al aanwezig, al gemerged of al gepusht levert
# een melding op en geen fout. Draai gerust opnieuw.
#
# Stap 5 is een echte toets, geen rapportage: hij faalt met exitcode 1 als een
# verwachting niet uitkomt.
#
# LET OP bij verlenging: dit certificaat verloopt 2026-09-02 en valt met
# `issuer: none` buiten `CertificateExpiringSoon` — die alert leest een metriek
# die cert-manager alleen voor Certificate-objecten produceert. Stap 5 meldt de
# resterende dagen; dat is de enige bewaking die er is.
#
# Writes: cluster (één TLS-secret in epe-prod, en het verwijderen van één
#         Certificate daar), een merge + `git push origin main` in
#         Nextcloud-base, en optioneel het opruimen van de hulp-worktree.
#         Sleutelmateriaal gaat alleen door een pipe, nooit naar schijf.
# Idempotent: ja, per stap
# Requires: bash, git, kubectl, jq, openssl
#
# Usage:
#   ./scripts/swap_epe_cert.sh status      # waar staan we, wijzigt niets
#   ./scripts/swap_epe_cert.sh all         # alles, met bevestiging per stap
#   ./scripts/swap_epe_cert.sh all --yes   # alles, zonder vragen
#   ./scripts/swap_epe_cert.sh 2           # één stap
#   ./scripts/swap_epe_cert.sh cleanup     # hulp-worktree en -branch opruimen
#
# Stappen:
#   1  preflight    tooling, cluster, bronsecret, worktree-commit, verify.sh
#   2  secret       open-epe-nl-tls zaaien in epe-prod uit namespace epe
#   3  merge        origin/main + epe-cert-issuer-none op main, en pushen
#   4  certificate  wachten tot de annotatie weg is, dan Certificate opruimen
#   5  verify       harde toets op het cluster (faalt met exitcode 1)
#
# Crontab: niet plannen. Dit is een eenmalige reparatie met een mens erbij.

set -euo pipefail

HUB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly HUB_DIR
readonly NB_DIR="${HUB_DIR}/../Nextcloud-base"

readonly SRC_NS="epe"
readonly SRC_SECRET="epe-prod-reactfront-woo-website-frontend-tls"
readonly DST_NS="epe-prod"
readonly DST_SECRET="open-epe-nl-tls"

readonly TLS_HOST="open.epe.nl"
readonly INGRESS="woo-website"
readonly ARGO_APP="epe-prod-reactfront"
readonly TENANT_FILE="nextcloud-platform/values/tenants/tenant-epe-prod.yaml"

# De wijziging staat op een lokale hulpbranch in een worktree, omdat main in
# Nextcloud-base divergeerde toen dit werk begon. Is de branch er niet meer
# (al gemerged en opgeruimd), dan slaat stap 3 dat deel over.
readonly WORK_BRANCH="epe-cert-issuer-none"

# Env-tunable: een trage sync of een dicht sync-window is geen reden om het
# script te moeten patchen.
readonly ARGO_WAIT_SECONDS="${ARGO_WAIT_SECONDS:-600}"
readonly ARGO_POLL_SECONDS="${ARGO_POLL_SECONDS:-15}"
# Onder deze grens is "het certificaat is geldig" geen goed nieuws meer.
readonly EXPIRY_WARN_DAYS="${EXPIRY_WARN_DAYS:-30}"

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
# bepaalt het totaal de exitcode. Anders zie je alleen de eerste afwijking.
check() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    ok "${label}: ${actual:-<leeg, zoals verwacht>}"
  else
    printf "${RED}FOUT${NC} %s\n  verwacht: %s\n  gekregen: %s\n" \
      "$label" "${expected:-<leeg>}" "${actual:-<leeg>}" >&2
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
  # stilzwijgend "nee" worden. main() vangt dat vooraf af; dit is het vangnet.
  [[ -t 0 ]] || fail "geen TTY om '$1' te beantwoorden — draai met --yes"
  read -r -p "$1 [j/N] " answer
  [[ "$answer" == "j" || "$answer" == "J" ]]
}

commits_ahead() {
  git -C "$NB_DIR" rev-list --count origin/main..main 2>/dev/null || echo "?"
}

# Het certificaat van een secret, zonder de privésleutel aan te raken.
crt_of() {
  local ns="$1" name="$2"
  kubectl -n "$ns" get secret "$name" -o jsonpath='{.data.tls\.crt}' 2>/dev/null \
    | base64 -d 2>/dev/null || true
}

days_left() {
  local ns="$1" name="$2" end epoch now
  end="$(crt_of "$ns" "$name" | openssl x509 -noout -enddate 2>/dev/null \
    | sed 's/^notAfter=//')"
  [[ -n "$end" ]] || { echo "?"; return 0; }
  epoch="$(date -d "$end" +%s 2>/dev/null || echo '')"
  [[ -n "$epoch" ]] || { echo "?"; return 0; }
  now="$(date +%s)"
  echo $(((epoch - now) / 86400))
}

issuer_annotation() {
  kubectl -n "$DST_NS" get ingress "$INGRESS" \
    -o jsonpath='{.metadata.annotations.cert-manager\.io/cluster-issuer}' 2>/dev/null \
    || echo ''
}

cert_exists() {
  kubectl -n "$DST_NS" get certificate "$DST_SECRET" >/dev/null 2>&1
}

argo_state() {
  kubectl -n argocd get application "$ARGO_APP" \
    -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || echo '?'
}

# Toon het sync-window dat een platform-sync tegenhoudt. Zonder deze uitleg
# lijkt een geblokkeerde uitrol op een kapotte uitrol.
show_sync_windows() {
  local windows
  windows="$(kubectl -n argocd get appproject react-platform \
    -o jsonpath='{range .spec.syncWindows[*]}  {.kind} schedule={.schedule} duur={.duration} apps={.applications} manualSync={.manualSync}{"\n"}{end}' \
    2>/dev/null || echo '')"
  [[ -z "$windows" ]] && return 0
  info "Sync-windows op AppProject react-platform:"
  printf '%s\n' "$windows"
  info "Valt 'nu' in een deny-window, dan wacht de ApplicationSet tot dat"
  info "venster voorbij is. Dat is een guardrail, geen storing."
}

# Draai verify.sh; toon de uitvoer alleen als hij faalt. De repo schrijft
# bestaande waarschuwingen naar stderr en die verzuipen anders het signaal.
run_verify() {
  local out
  out="$(mktemp)"
  info "verify.sh in Nextcloud-base..."
  if (cd "$NB_DIR" && ./scripts/verify.sh) >"$out" 2>&1; then
    ok "Nextcloud-base verify groen"
    rm -f "$out"
  else
    sed 's/^/  /' "$out" >&2
    rm -f "$out"
    fail "verify.sh faalt in Nextcloud-base — niets gepusht"
  fi
}

# Welke bestanden conflicteren écht? `git diff --name-only HEAD...ref` is hier
# het verkeerde gereedschap: dat toont álle verschillen, dus ook bestanden die
# alleen op de andere kant nieuw zijn en probleemloos mergen. Dat gebeurde op
# 2026-08-11: tenant-epe-prod.yaml stond in de conflictlijst terwijl er één
# echt conflict was. `merge-tree` doet de merge in het geheugen — geen index,
# geen werkboom — en noemt precies de conflicterende paden.
#
# Uitvoer van merge-tree bij een conflict: eerst de tree-oid, dan de paden, dan
# een lege regel met daarna de meldingen. Alleen het middenstuk willen we. De
# exitcode is 1 bij een conflict, dus `|| true`, anders breekt pipefail af.
conflicting_files() {
  local ref="$1" out
  out="$(git -C "$NB_DIR" merge-tree --write-tree --name-only HEAD "$ref" 2>/dev/null || true)"
  printf '%s\n' "$out" | sed -n '2,/^$/p' | sed '/^$/d'
}

# Merge zonder ooit zelf een conflict op te lossen. Een conflict in een
# tenantbestand is een inhoudelijke keuze en geen scriptbeslissing: afbreken,
# de werkboom teruggeven zoals hij was, en het aan de mens laten.
merge_ref() {
  local ref="$1" label="$2"

  git -C "$NB_DIR" rev-parse --verify --quiet "$ref" >/dev/null \
    || { warn "${label} (${ref}) bestaat niet — overgeslagen"; return 0; }

  if git -C "$NB_DIR" merge-base --is-ancestor "$ref" HEAD; then
    ok "${label} zit al in main"
    return 0
  fi

  info
  info "${label} brengt mee:"
  git -C "$NB_DIR" log --oneline "HEAD..${ref}" | sed 's/^/  /'
  info

  if git -C "$NB_DIR" merge --no-edit "$ref" >/dev/null 2>&1; then
    ok "${label} gemerged op main"
    return 0
  fi

  git -C "$NB_DIR" merge --abort 2>/dev/null || true
  info "Conflicterende bestanden:"
  conflicting_files "$ref" | sed 's/^/  /'
  fail "${label} conflicteert met main. De merge is afgebroken en de werkboom staat weer zoals hij was. Los het met de hand op: git -C ${NB_DIR} merge ${ref}"
}

push_main() {
  if [[ "$(commits_ahead)" == "0" ]]; then
    ok "Nextcloud-base: main staat al op de remote"
    return 0
  fi

  info
  info "Nextcloud-base heeft $(commits_ahead) commit(s) klaar:"
  git -C "$NB_DIR" log --oneline origin/main..main | sed 's/^/  /'
  info

  confirm "Push Nextcloud-base naar origin/main?" || fail "afgebroken door gebruiker"

  # Geen --force in welke vorm dan ook. Een afwijzing heeft twee heel
  # verschillende oorzaken en die niet uit elkaar houden stuurt je de verkeerde
  # kant op: `pull --rebase` helpt niets tegen een branch-ruleset.
  local out rc
  out="$(mktemp)"
  set +e
  git -C "$NB_DIR" push origin main >"$out" 2>&1
  rc=$?
  set -e
  cat "$out"

  if [[ $rc -eq 0 ]]; then
    rm -f "$out"
    ok "Nextcloud-base gepusht naar origin/main"
    return 0
  fi

  if grep -qE 'GH013|repository rule violations|protected branch|must be made through a pull request' "$out"; then
    rm -f "$out"
    fail "GitHub weigert een directe push naar main — er staat een branch-ruleset op. Open een PR, of pas de ruleset aan. Dat laatste is een bewuste beveiligingskeuze; dit script doet dat niet voor je."
  fi

  if grep -qE 'non-fast-forward|fetch first|behind its remote' "$out"; then
    rm -f "$out"
    fail "origin/main is verderop. Draai stap 3 opnieuw; die merget origin/main eerst binnen."
  fi

  rm -f "$out"
  fail "push afgewezen, zie de uitvoer hierboven"
}

# --------------------------------------------------------------------------
step_1_preflight() {
  banner "Stap 1 — preflight"

  local tool
  for tool in git kubectl jq openssl; do
    command -v "$tool" >/dev/null || fail "${tool} ontbreekt"
  done
  ok "tooling compleet"

  kubectl get ns "$SRC_NS" >/dev/null 2>&1 || fail "namespace ${SRC_NS} niet bereikbaar"
  kubectl get ns "$DST_NS" >/dev/null 2>&1 || fail "namespace ${DST_NS} niet bereikbaar"
  ok "cluster bereikbaar (context: $(kubectl config current-context))"

  # Het bronsecret moet er zijn EN over deze host gaan. Een naam die klopt maar
  # een cert voor een andere host draagt, is de duurste fout die hier mogelijk is.
  local subject san
  subject="$(crt_of "$SRC_NS" "$SRC_SECRET" | openssl x509 -noout -subject 2>/dev/null || true)"
  [[ -n "$subject" ]] || fail "bronsecret ${SRC_NS}/${SRC_SECRET} bestaat niet of draagt geen tls.crt"
  san="$(crt_of "$SRC_NS" "$SRC_SECRET" \
    | openssl x509 -noout -ext subjectAltName 2>/dev/null | tr -d ' ')"
  [[ "$san" == *"DNS:${TLS_HOST}"* ]] \
    || fail "bronsecret dekt ${TLS_HOST} niet — SAN: ${san:-<leeg>}"
  ok "bronsecret dekt ${TLS_HOST} (${subject#subject=})"

  local left
  left="$(days_left "$SRC_NS" "$SRC_SECRET")"
  if [[ "$left" == "?" ]]; then
    warn "kon de vervaldatum van het bronsecret niet lezen"
  elif [[ "$left" -lt 0 ]]; then
    fail "het bronsecret is ${left#-} dagen VERLOPEN — overzetten heeft geen zin, vraag een verse bundel bij gemeente Epe"
  elif [[ "$left" -lt "$EXPIRY_WARN_DAYS" ]]; then
    warn "het bronsecret verloopt over ${left} dagen — zet het over, maar vraag tegelijk een verse bundel bij gemeente Epe"
  else
    ok "bronsecret geldig, nog ${left} dagen"
  fi

  git -C "$NB_DIR" fetch -q origin main
  ok "origin/main opgehaald"

  local branch dirty
  branch="$(git -C "$NB_DIR" branch --show-current)"
  [[ "$branch" == "main" ]] || fail "Nextcloud-base staat op '${branch}', niet op main"

  # Untracked rommel telt niet mee; ongecommitte wijzigingen aan gevolgde
  # bestanden wel — die zouden anders stilletjes buiten de push vallen.
  dirty="$(git -C "$NB_DIR" status --porcelain --untracked-files=no)"
  if [[ -n "$dirty" ]]; then
    printf '%s\n' "$dirty" | sed 's/^/  /' >&2
    fail "Nextcloud-base heeft ongecommitte wijzigingen — commit ze of zet ze weg"
  fi
  ok "Nextcloud-base: main, schoon, $(commits_ahead) commit(s) vóór origin/main"

  run_verify
}

# --------------------------------------------------------------------------
step_2_secret() {
  banner "Stap 2 — certificaat overzetten naar ${DST_NS}"

  if kubectl -n "$DST_NS" get secret "$DST_SECRET" >/dev/null 2>&1; then
    ok "secret ${DST_NS}/${DST_SECRET} bestaat al"
    crt_of "$DST_NS" "$DST_SECRET" \
      | openssl x509 -noout -subject -issuer -dates | sed 's/^/  /'
    info
    info "Vervangen? kubectl -n ${DST_NS} delete secret ${DST_SECRET}"
    return 0
  fi

  info "Bron : ${SRC_NS}/${SRC_SECRET}"
  info "Doel : ${DST_NS}/${DST_SECRET}   (letterlijk de secretName uit ${TENANT_FILE})"
  info
  info "jq gooit alle annotaties, labels en ownerReferences weg. Dat is geen"
  info "netheid maar de kern: zonder Argo-tracking pruunt Argo het secret niet,"
  info "en zonder cert-manager-annotaties claimt cert-manager het niet."
  info "De privésleutel gaat alleen door de pipe, niet naar schijf of terminal."
  confirm "Doorgaan?" || fail "afgebroken door gebruiker"

  kubectl -n "$SRC_NS" get secret "$SRC_SECRET" -o json \
    | jq --arg n "$DST_SECRET" --arg ns "$DST_NS" \
        '{apiVersion, kind, type, data, metadata: {name: $n, namespace: $ns}}' \
    | kubectl apply -f - \
    || fail "kon het secret niet aanmaken"

  ok "secret ${DST_NS}/${DST_SECRET} gezaaid"
}

# --------------------------------------------------------------------------
step_3_merge() {
  banner "Stap 3 — tenantwijziging op main en naar de remote"
  info "Zet frontend.tls.issuer van letsencrypt-prod naar none. Daarmee zet de"
  info "react-tenants-ApplicationSet geen cluster-issuer-annotatie meer op de"
  info "ingress: geen shim, geen Certificate, niets dat het klantcertificaat"
  info "kan overschrijven."
  info

  kubectl -n "$DST_NS" get secret "$DST_SECRET" >/dev/null 2>&1 \
    || fail "secret ${DST_SECRET} ontbreekt — draai stap 2 eerst, anders staat de site na de sync op het fake-cert"
  ok "TLS-secret aanwezig"

  git -C "$NB_DIR" fetch -q origin main

  # origin/main eerst binnen, dan onze wijziging. Andersom kan een push die
  # verderop is alsnog afketsen op non-fast-forward.
  merge_ref "origin/main" "origin/main"
  merge_ref "$WORK_BRANCH" "de epe-wijziging"

  # De merge moet ook echt in het bestand geland zijn. `grep` op het resultaat
  # is de goedkoopste toets die er is en vangt een lege of verkeerde merge.
  grep -qE '^ *issuer: none' "${NB_DIR}/${TENANT_FILE}" \
    || fail "${TENANT_FILE} staat niet op 'issuer: none' — merge nagekeken?"
  ok "${TENANT_FILE} staat op issuer: none"

  run_verify
  push_main
}

# --------------------------------------------------------------------------
step_4_certificate() {
  banner "Stap 4 — het lege Certificate opruimen"

  if ! cert_exists; then
    ok "geen Certificate ${DST_SECRET} meer in ${DST_NS}"
    return 0
  fi

  # Pas verwijderen als de annotatie weg is. Anders maakt de ingress-shim het
  # Certificate binnen seconden terug en heb je niets opgeruimd.
  local deadline=$((SECONDS + ARGO_WAIT_SECONDS))
  local annotation
  info "Wachten tot de cluster-issuer-annotatie van de ingress verdwenen is"
  info "(max ${ARGO_WAIT_SECONDS}s)..."
  while ((SECONDS < deadline)); do
    annotation="$(issuer_annotation)"
    if [[ -z "$annotation" ]]; then
      ok "annotatie weg — de ApplicationSet heeft issuer: none opgepikt"
      break
    fi
    printf '  annotatie nog %s ... \r' "$annotation"
    sleep "$ARGO_POLL_SECONDS"
  done

  if [[ -n "$(issuer_annotation)" ]]; then
    info
    warn "De ingress draagt na ${ARGO_WAIT_SECONDS}s nog cluster-issuer=$(issuer_annotation)."
    show_sync_windows
    info
    info "De push is geland; alleen de uitrol wacht. Draai stap 4 straks opnieuw."
    info "Nu verwijderen heeft geen zin: de shim maakt het Certificate terug."
    return 0
  fi

  info "Verwijdert certificate/${DST_SECRET} in ${DST_NS}, en cascadegewijs zijn"
  info "CertificateRequest, Order en Challenge. Het secret blijft staan."
  confirm "Doorgaan?" || fail "afgebroken door gebruiker"

  kubectl -n "$DST_NS" delete certificate "$DST_SECRET" \
    || fail "kon het Certificate niet verwijderen"
  ok "Certificate opgeruimd"
}

# --------------------------------------------------------------------------
step_5_verify() {
  banner "Stap 5 — harde toets op het cluster"
  FAILURES=0

  # Meld de oorzaak vóór de symptomen. Draagt de ingress nog de annotatie, dan
  # zijn twee verwachtingen hieronder gegarandeerd rood en zegt dat niets over
  # de wijziging zelf.
  local annotation
  annotation="$(issuer_annotation)"
  if [[ -n "$annotation" ]]; then
    warn "De ingress draagt nog cluster-issuer=${annotation} — de tenantwijziging"
    warn "is nog niet gesynct. Twee verwachtingen hieronder falen daardoor sowieso."
    show_sync_windows
    info
  fi

  # 1. Bestaat het secret, en is het een echt TLS-secret?
  check "secret type" "kubernetes.io/tls" \
    "$(kubectl -n "$DST_NS" get secret "$DST_SECRET" \
        -o jsonpath='{.type}' 2>/dev/null || echo '')"

  # 2. Verwijst de ingress naar precies dat secret?
  check "ingress TLS-secret" "$DST_SECRET" \
    "$(kubectl -n "$DST_NS" get ingress "$INGRESS" \
        -o jsonpath='{.spec.tls[0].secretName}' 2>/dev/null || echo '')"

  # 3. De kern van de none-tak: er hoort GEEN cert-manager-annotatie te staan.
  check "cert-manager-annotatie (hoort leeg)" "" "$annotation"

  # 4. En dus ook geen Certificate meer.
  check "Certificate weg" "afwezig" \
    "$(cert_exists && echo 'aanwezig' || echo 'afwezig')"

  # 5. Serveert de host werkelijk óns cert? Niet wat in het secret staat, maar
  #    wat er over de lijn komt — dat is het enige dat een bezoeker merkt.
  local served subject issuer
  served="$(echo | timeout 10 openssl s_client -connect "${TLS_HOST}:443" \
    -servername "$TLS_HOST" 2>/dev/null || true)"
  subject="$(printf '%s' "$served" | openssl x509 -noout -subject 2>/dev/null \
    | sed 's/.*CN *= *//; s/,.*//' || echo '')"
  issuer="$(printf '%s' "$served" | openssl x509 -noout -issuer 2>/dev/null || echo '')"
  check "geserveerd cert CN" "$TLS_HOST" "$subject"
  if [[ "$issuer" == *Sectigo* ]]; then
    ok "geserveerd cert issuer: ${issuer#issuer=}"
  else
    printf "${RED}FOUT${NC} %s\n  verwacht: een Sectigo-issuer\n  gekregen: %s\n" \
      "geserveerd cert issuer" "${issuer:-<leeg>}" >&2
    FAILURES=$((FAILURES + 1))
  fi

  # 6. Argo moet het ook eens zijn met zichzelf.
  check "Argo sync/health" "Synced/Healthy" "$(argo_state)"

  # 7. Geen toets maar een waarschuwing, en de enige bewaking die dit cert
  #    heeft: met issuer: none bestaat er geen Certificate, dus produceert
  #    cert-manager geen expiry-metriek en dekt CertificateExpiringSoon dit niet.
  local left
  left="$(days_left "$DST_NS" "$DST_SECRET")"
  info
  if [[ "$left" == "?" ]]; then
    warn "kon de vervaldatum niet lezen"
  elif [[ "$left" -lt "$EXPIRY_WARN_DAYS" ]]; then
    warn "Dit certificaat verloopt over ${left} dagen en valt buiten CertificateExpiringSoon."
    warn "Vraag een verse bundel bij gemeente Epe en zet die over met stap 2."
  else
    info "Verloopt over ${left} dagen. Geen alert-dekking: zet het zelf in de agenda."
  fi

  info
  if [[ "$FAILURES" -eq 0 ]]; then
    ok "alle verwachtingen uitgekomen"
  else
    fail "${FAILURES} verwachting(en) niet uitgekomen"
  fi
}

# --------------------------------------------------------------------------
cmd_cleanup() {
  banner "Opruimen — hulp-worktree en -branch"

  local wt="${NB_DIR}/.claude/worktrees/epe-cert"

  git -C "$NB_DIR" rev-parse --verify --quiet "$WORK_BRANCH" >/dev/null \
    || { ok "branch ${WORK_BRANCH} bestaat niet (meer)"; return 0; }

  git -C "$NB_DIR" merge-base --is-ancestor "$WORK_BRANCH" main \
    || fail "${WORK_BRANCH} zit nog niet in main — draai stap 3 eerst. Opruimen zou werk weggooien."
  ok "${WORK_BRANCH} zit in main"

  confirm "Worktree en branch verwijderen?" || fail "afgebroken door gebruiker"

  [[ -d "$wt" ]] && git -C "$NB_DIR" worktree remove "$wt"
  # `-d` en niet `-D`: een veilige delete weigert als de branch tóch niet
  # gemerged is. De controle hierboven is de bedoeling, dit is het vangnet.
  git -C "$NB_DIR" branch -d "$WORK_BRANCH"
  ok "opgeruimd"
}

# --------------------------------------------------------------------------
cmd_status() {
  banner "Stand van zaken"

  printf '  Nextcloud-base   branch=%-6s %s\n' \
    "$(git -C "$NB_DIR" branch --show-current 2>/dev/null)" \
    "$(if [[ "$(commits_ahead)" == "0" ]]; then
         echo 'gelijk aan origin/main'
       else
         echo "$(commits_ahead) commit(s) te pushen"
       fi)"

  # Het tenantbestand kan drie standen hebben, en ze zien er van buiten
  # hetzelfde uit als je alleen op de grep-uitkomst let: nog niet op main,
  # op main met de oude issuer, of om. Alle drie apart benoemen.
  if [[ ! -f "${NB_DIR}/${TENANT_FILE}" ]]; then
    printf '  tenantbestand    %s\n' 'niet op main (zit nog in de hulpbranch of op origin/main)'
  elif grep -qE '^ *issuer: none' "${NB_DIR}/${TENANT_FILE}"; then
    printf '  tenantbestand    %s\n' 'issuer: none'
  else
    printf '  tenantbestand    %s\n' \
      "$(grep -E '^ *issuer:' "${NB_DIR}/${TENANT_FILE}" | tr -d ' ')"
  fi

  info
  if kubectl -n "$DST_NS" get secret "$DST_SECRET" >/dev/null 2>&1; then
    ok "secret ${DST_NS}/${DST_SECRET} aanwezig, verloopt over $(days_left "$DST_NS" "$DST_SECRET") dagen"
  else
    info "  secret ${DST_NS}/${DST_SECRET}: nog niet gezaaid (stap 2)"
  fi

  printf '  ingress-annotatie  %s\n' "$(issuer_annotation || true)"
  printf '  Certificate        %s\n' "$(cert_exists && echo 'aanwezig' || echo 'weg')"
  printf '  argo %s  %s\n' "$ARGO_APP" "$(argo_state)"
}

usage() {
  sed -n '/^# Usage:/,/^# Crontab/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

main() {
  local step="${1:-status}"
  shift || true
  # Onbekende argumenten weigeren, niet slikken. `status all` liep op
  # 2026-08-11 als `status` omdat alleen $1 werd gelezen — de gebruiker dacht
  # dat hij de uitrol startte en zag alleen een rapportje.
  local arg
  for arg in "$@"; do
    case "$arg" in
      --yes) ASSUME_YES=1 ;;
      *) fail "onbekend argument '${arg}' — één stap per aanroep, zie --help" ;;
    esac
  done

  # Stappen die iets muteren vragen om bevestiging. Zonder TTY kan dat niet, en
  # dan zou het script pas halverwege stuklopen op een vraag die niemand kan
  # beantwoorden. Vooraf stoppen, met de oplossing erbij.
  case "$step" in
    2|3|4|all|cleanup)
      if [[ ! -t 0 ]] && [[ "$ASSUME_YES" -eq 0 ]]; then
        fail "geen interactieve shell — draai '${step} --yes', of start het script vanaf een terminal"
      fi
      ;;
  esac

  case "$step" in
    status) cmd_status ;;
    1) step_1_preflight ;;
    2) step_2_secret ;;
    3) step_3_merge ;;
    4) step_4_certificate ;;
    5) step_5_verify ;;
    cleanup) cmd_cleanup ;;
    all)
      step_1_preflight
      step_2_secret
      step_3_merge
      step_4_certificate
      step_5_verify
      ;;
    -h|--help) usage ;;
    *) fail "onbekende stap '${step}' — zie --help" ;;
  esac
}

main "$@"
