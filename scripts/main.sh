#!/bin/bash
# platform: GitHub's Linux runners only (bash) -- this Action runs nowhere else
#   usage: main.sh
#          env in:  MVM_* (scripts/inputs.sh), MVM_PREPARE, MVM_RUN, MVM_IMAGE_KEY, MVM_TOKEN
#          out:     run's exit status; cache-after-prepare-hit in $GITHUB_OUTPUT; the guest left
#                   running for later "ssh mavericks" and custom-shell steps
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
data="${MVM_DATA_DIR:?main.sh: MVM_DATA_DIR is unset}"
# siblings, so a delta's relative backing file resolves: the layer's ../box/box_0.img and the
# prepared's ../layer/box_0.img
box="$data/box" layer="$data/layer" prepared="$data/prepared"
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
  find "$box" "$layer" "$prepared" -mindepth 1 -delete 2>/dev/null || true
  exit "$status"
}
trap 'finish $?' EXIT

prepared_hit=false layer_built=false base_built=false
key="" lkey="" pkey=""

# spec: tests/main.bats -- every failure names its image (base, layer or prepared) and its step,
#       even when the step itself failed without a word
die() { echo "::error title=mavericks-vm::$1 failed"; exit 1; }

# spec: tests/main.bats -- room is checked before each download or build, never after
build_base() {
  step space.sh miss || exit 1
  step build.sh mavericks "$box" || die "building the base image"
  base_built=true
}
build_layer() {  # over the base in $box
  step space.sh layer || exit 1
  step layer.sh "$box" "$layer" || die "building the layer image"
  layer_built=true
}
push() {  # $1 = base, layer or prepared; $2 = its key; $3 = its dir
  step image.sh push "$2" "$3" || die "pushing the $1 image"
  pushed "$2"
}

get_base() {  # leaves the base guest in $box: pulled, or built and pushed
  key="$(step key.sh --base)" || die "computing the base image's key"
  step image.sh pull "$key" "$box"; rc=$?
  case "$rc" in
    0) ;;
    3) build_base; push base "$key" "$box" ;;
    *) die "pulling the base image" ;;
  esac
}

# spec: tests/main.bats -- the layer is a delta over the base, so it is used only with the base it
#       was cached beside; a layer whose base is gone is a broken set, built again over a new base
get_layer() {  # $1 = "checked" when room for a hit was already checked; leaves the layer guest in $layer
  lkey="$(step key.sh --layer)" || die "computing the layer image's key"
  [ "${1:-}" = checked ] || step space.sh hit || exit 1
  step image.sh pull "$lkey" "$layer"; rc=$?
  case "$rc" in
    0) get_base
       [ "$base_built" = true ] || return 0
       echo "mavericks-vm: the layer image was cached but its base image was not; building the layer again"
       rm -rf "$layer" || die "removing the layer image whose base is gone" ;;
    3) get_base ;;
    *) die "pulling the layer image" ;;
  esac
  build_layer
  push layer "$lkey" "$layer"
}

# spec: tests/main.bats -- disable-cache builds the base and the layer, and pulls and pushes nothing
if [ "${MVM_DISABLE_CACHE:-false}" = true ]; then
  build_base
  build_layer
# spec: tests/main.bats -- with no prepare, the prepared guest is the layer guest: it is cached as
#       the layer, and nothing is cached under a prepared key
elif [ "${MVM_CACHE_AFTER_PREPARE:-false}" = true ] && [ -n "${MVM_PREPARE:-}" ]; then
  pkey="$(MVM_PREPARE="${MVM_PREPARE:-}" step key.sh --prepared)" || die "computing the prepared image's key"
  step space.sh hit || exit 1
  step image.sh pull "$pkey" "$prepared"; rc=$?
  case "$rc" in
    0) prepared_hit=true ;;
    3) ;;
    *) die "pulling the prepared image" ;;
  esac
  get_layer checked
  # spec: tests/main.bats -- the prepared image is a delta over the layer; over a layer built again
  #       here it is a broken chain, so it is thrown away and prepared again
  if [ "$prepared_hit" = true ] && [ "$layer_built" = true ]; then
    echo "mavericks-vm: the prepared image was cached but its layer image was not; preparing again"
    rm -rf "$prepared" || die "removing the prepared image whose layer is gone"
    prepared_hit=false
  fi
else
  get_layer
fi
echo "cache-after-prepare-hit=$prepared_hit" >> "${GITHUB_OUTPUT:-/dev/null}"

if [ "$prepared_hit" = true ]; then
  step boot.sh "$prepared" || die "booting the prepared image"
else
  step boot.sh "$layer" || die "booting the layer image"
fi
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
    #       cache-after-prepare is one more encrypted image under the prepared key, a delta over
    #       the layer
    step space.sh prepare || exit 1
    step snapshot.sh "$layer" "$prepared" || die "snapshotting the prepared image"
    push prepared "$pkey" "$prepared"
    step boot.sh "$prepared" || die "booting the prepared image"
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
