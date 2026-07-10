#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# role: tool
#
# scripts/clone_all.sh — kloon of ververs alle deelnemende Conduction-repos
# als zusters van deze hub-map, met de juiste Codeberg-remotes.
#
# Bestaande checkouts worden alleen gefetcht (geen merge/reset — jouw
# werk blijft van jou). Ontbrekende repos worden gekloond.
#
# Writes: zusterdirectories naast deze repo (clones); fetch in bestaande
# Idempotent: ja
# Requires: git; netwerk naar codeberg.org
#
# Usage:
#   ./scripts/clone_all.sh
#   ROOT=/ander/pad ./scripts/clone_all.sh

set -euo pipefail

readonly ROOT="${ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
readonly REPOS=(
  techbook handbook docs-mcp
  Nextcloud-base React-base talos cluster-infra cluster-config
  monitoring KeyCloak openwoo-app-config
)

main() {
  local repo url
  for repo in "${REPOS[@]}"; do
    url="https://codeberg.org/Conduction/${repo}.git"
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
