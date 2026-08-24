#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# role: tool
#
# scripts/clone_all.sh — kloon of ververs alle deelnemende Conduction-repos
# als zusters van deze hub-map, met de juiste GitHub-remotes (ConductionNL).
#
# Bestaande checkouts worden alleen gefetcht (geen merge/reset — jouw
# werk blijft van jou). Ontbrekende repos worden gekloond.
#
# Deze werkkopieën zijn sinds 2026-08-03 óók de bron van de handboek-MCP
# (DOCS_MCP_LOCAL_ROOT); klonen van de juiste remote is daarmee niet alleen
# gemak maar bepaalt wat agents als grondwaarheid lezen.
#
# Tot 2026-08-03 kloonde dit script van codeberg.org terwijl deze header al
# GitHub claimde — header en code spraken elkaar tegen. Alle elf repos hebben
# `origin` op github.com/ConductionNL, dus dat is nu ook de kloonbron.
# Codeberg blijft de fallback-forge (talos/Forgejo draait daar), maar is niet
# meer waar een verse checkout vandaan komt.
#
# Writes: zusterdirectories naast deze repo (clones); fetch in bestaande
# Idempotent: ja
# Requires: git; netwerk naar github.com
#
# Usage:
#   ./scripts/clone_all.sh
#   ROOT=/ander/pad ./scripts/clone_all.sh
#   FORGE=https://codeberg.org/Conduction ./scripts/clone_all.sh   # fallback

set -euo pipefail

readonly ROOT="${ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
readonly FORGE="${FORGE:-https://github.com/ConductionNL}"
readonly REPOS=(
  techbook handbook
  Nextcloud-base react-base talos cluster-infra cluster-config
  monitoring KeyCloak openwoo-app-config
  claude-plugins
)

# De lokale mapnaam is niet altijd de repo-naam op de forge. Alleen de
# afwijkingen staan hier; de rest is één-op-één.
declare -rA REMOTE_NAME=(
  [react-base]="React-base"
  [talos]="Talos"
)

main() {
  local repo url
  for repo in "${REPOS[@]}"; do
    url="${FORGE}/${REMOTE_NAME[${repo}]:-${repo}}.git"
    if [[ -d "${ROOT}/${repo}/.git" ]]; then
      git -C "${ROOT}/${repo}" fetch --all --quiet \
        && echo "${repo}: gefetcht" \
        || echo "waarschuwing: ${repo}: fetch faalde" >&2
    else
      git clone --quiet "${url}" "${ROOT}/${repo}" \
        && echo "${repo}: gekloond" \
        || echo "waarschuwing: ${repo}: clone faalde (private? token nodig)" >&2
    fi
  done
  echo ""
  echo "klaar — root: ${ROOT}"
}

main "$@"
