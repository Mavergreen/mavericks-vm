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
store="${MVM_STORE:-registry}"

# spec: docs/superpowers/specs/2026-10-06-mavericks-vm-design.md "Two tiers" (in
#       packer-plugin-macosx) -- in the repo tier, action.yml's save step saves the one image this
#       run newly wrote, named here as soon as it exists, so a failing run still keeps it
pushed() {  # $1 = the key just pushed
  if [ "$store" = file ]; then echo "cache-save-key=$1" >> "${GITHUB_OUTPUT:-/dev/null}"; fi
}

# spec: tests/safety.bats -- GitHub masks a value that came from a secret, but not one that came
#       from anywhere else; masking it here covers both
if [ -n "${MVM_IMAGE_KEY:-}" ]; then echo "::add-mask::$MVM_IMAGE_KEY"; fi

# spec: tests/main.bats -- on a miss the key was first parsed at the push, after the 40-minute
#       build; a recipient or a passphrase saved as the secret now fails here, before anything
if ! printf '%s\n' "${MVM_IMAGE_KEY:-}" | age-keygen -y > /dev/null 2>&1; then
  echo "::error title=mavericks-vm::image-key is not an age identity: it should be the line age-keygen prints starting AGE-SECRET-KEY-1, not the age1... public key or a passphrase"
  exit 1
fi

# shellcheck disable=SC2317  # finish runs from the EXIT trap below
finish() {
  status=$1
  if [ "$status" -ne 0 ] && [ "${MVM_DEBUG_ON_ERROR:-false}" = true ]; then
    echo "::group::mavericks-vm: the guest's system.log and serial console"
    ssh -F "$HOME/.ssh/config" mavericks 'tail -n 100 /var/log/system.log' 2>&1 || true
    tail -n 40 "$data/serial.log" 2>/dev/null || true
    echo "::endgroup::"
  fi
  # spec: docs/superpowers/specs/2026-10-06-mavericks-vm-design.md "Safety" -- the decrypted guest
  #       leaves the disk when the step ends; a running QEMU keeps the files it has open, so later
  #       steps' ssh and custom shell still work (a composite action has no post step to do this)
  find "$data/box" "$data/prepared" -mindepth 1 -delete 2>/dev/null || true
  exit "$status"
}
trap 'finish $?' EXIT

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
       # spec: tests/main.bats -- a repo's 10 GB cache cannot hold a base and a prepared guest
       #       both, so with cache-after-prepare the repo tier keeps only the prepared one
       if [ "$store" = file ] && [ -n "$pkey" ]; then return; fi
       step image.sh push "$key" "$box" || exit 1
       pushed "$key" ;;
    *) exit 1 ;;
  esac
}

# spec: tests/main.bats -- with no prepare, the prepared guest is the base guest: it is cached as
#       the base, or the repo store, which keeps only the prepared one, kept nothing at all
if [ "${MVM_CACHE_AFTER_PREPARE:-false}" = true ] && [ "${MVM_DISABLE_CACHE:-false}" != true ] \
   && [ -n "${MVM_PREPARE:-}" ]; then
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
    step space.sh prepare || exit 1
    step snapshot.sh "$box" "$data/prepared" || exit 1
    step image.sh push "$pkey" "$data/prepared" || exit 1
    pushed "$pkey"
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
