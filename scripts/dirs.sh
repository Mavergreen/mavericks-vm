#!/bin/bash
# platform: GitHub's Linux runners only (bash, passwordless sudo) -- this Action runs nowhere else
#   usage: dirs.sh
#          env in:  MVM_DATA_DIR, MVM_CACHE_DIR (scripts/inputs.sh)
#          out:     both directories exist and belong to the runner's user
set -euo pipefail

data="${MVM_DATA_DIR:?dirs.sh: MVM_DATA_DIR is unset}"
cache="${MVM_CACHE_DIR:?dirs.sh: MVM_CACHE_DIR is unset}"

# platform: GitHub's ubuntu-24.04 image leaves /mnt, data-dir's default parent, to root (seen
#           2026-10-06, run 37488469195), so the runner's user cannot make anything there itself
if ! mkdir -p "$data" "$cache" 2>/dev/null; then
  sudo mkdir -p "$data" "$cache"
  sudo chown "$(id -u):$(id -g)" "$data" "$cache"
fi
