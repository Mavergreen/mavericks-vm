#!/bin/bash
# platform: GitHub's Linux runners only (bash) -- this Action runs nowhere else
#   usage: main.sh
#          env in:  MVM_* (scripts/inputs.sh), MVM_PREPARE, MVM_RUN, MVM_IMAGE_KEY, MVM_TOKEN
#          out:     run's exit status; cache-after-prepare-hit in $GITHUB_OUTPUT; the guest left
#                   running for later "ssh mavericks" and custom-shell steps
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
data="${MVM_DATA_DIR:?main.sh: MVM_DATA_DIR is unset}"
box="$data/box"
mkdir -p "$data"
step() { bash "$here/$1" "${@:2}"; }

prepared_hit=false
key="" pkey=""

# spec: tests/main.bats -- room is checked before each download or build, never after
get_base() {  # $1 = "checked" when room for a hit was already checked; leaves the guest in $box
  if [ "${MVM_DISABLE_CACHE:-false}" = true ]; then
    step space.sh miss || exit 1
    step build.sh "$box" || exit 1
    return
  fi
  [ "${1:-}" = checked ] || step space.sh hit || exit 1
  step image.sh pull "$key" "$box"; rc=$?
  case "$rc" in
    0) ;;
    3) step space.sh miss || exit 1
       step build.sh "$box" || exit 1
       step image.sh push "$key" "$box" || exit 1 ;;
    *) exit 1 ;;
  esac
}

if [ "${MVM_CACHE_AFTER_PREPARE:-false}" = true ] && [ "${MVM_DISABLE_CACHE:-false}" != true ]; then
  pkey="$(MVM_PREPARE="${MVM_PREPARE:-}" step key.sh --prepared)" || exit 1
  step space.sh hit || exit 1
  step image.sh pull "$pkey" "$box"; rc=$?
  case "$rc" in
    0) prepared_hit=true ;;
    3) key="$(step key.sh)" || exit 1; get_base checked ;;
    *) exit 1 ;;
  esac
else
  key="$(step key.sh)" || exit 1
  get_base
fi
echo "cache-after-prepare-hit=$prepared_hit" >> "${GITHUB_OUTPUT:-/dev/null}"

step boot.sh "$box" || exit 1
step shell-wrapper.sh --install || exit 1
if [ "${MVM_SYNC_TIME:-false}" = true ]; then
  # platform: 10.9's date sets the clock from MMDDhhmmYYYY.SS, and the guest has no other source
  ssh -F "$HOME/.ssh/config" mavericks "sudo date -u $(date -u +%m%d%H%M%Y.%S)" > /dev/null || exit 1
fi
step sync.sh in || exit 1

scriptfile() { f="$(mktemp "$data/script.XXXXXX")"; printf '%s\n' "$1" > "$f"; printf '%s' "$f"; }

if [ -n "${MVM_PREPARE:-}" ] && [ "$prepared_hit" = false ]; then
  step run.sh "$(scriptfile "$MVM_PREPARE")"; rc=$?
  [ "$rc" -eq 0 ] || exit "$rc"
  if [ -n "$pkey" ]; then
    # spec: docs/superpowers/specs/2026-10-06-mavericks-vm-design.md "The cache" --
    #       cache-after-prepare is a second encrypted image under the prepared key
    step snapshot.sh "$box" "$data/prepared" || exit 1
    step image.sh push "$pkey" "$data/prepared" || exit 1
    step boot.sh "$data/prepared" || exit 1
    step sync.sh in || exit 1
  fi
fi

status=0
if [ -n "${MVM_RUN:-}" ]; then
  step run.sh "$(scriptfile "$MVM_RUN")"; status=$?
fi
# spec: tests/main.bats -- the workspace comes back whatever run's status was
step sync.sh out || exit 1
exit "$status"
