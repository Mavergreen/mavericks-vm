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
#       packer-plugin-macosx) -- in the repo tier, action.yml's save step saves the whole blob dir
#       (this run's base, layer and prepared images, nothing else) once this run has stored any
#       image in it; so after each successful push this names the top key (the prepared image's, or
#       else the layer's), and a failing run still keeps what it stored. A run that stored nothing
#       names nothing, and saves nothing.
top=""
pushed() {
  if [ "$store" = file ]; then echo "cache-save-key=$top" >> "${GITHUB_OUTPUT:-/dev/null}"; fi
}

# spec: tests/main.bats -- the repo tier keeps only this run's set: every <64-hex>.tar.zst.age in
#       the blob dir that is none of this run's keys is deleted, so a restored set's stale members
#       free their disk before anything is pulled or built, and a failing run never saves them;
#       anything else in the dir is left alone
prune_blobs() {  # $@ = this run's keys
  local f k keep
  [ -d "${MVM_BLOB_DIR:-}" ] || return 0
  for f in "$MVM_BLOB_DIR"/*.tar.zst.age; do
    [ -e "$f" ] || continue
    k="$(basename "$f" .tar.zst.age)"
    [[ "$k" =~ ^[0-9a-f]{64}$ ]] || continue
    keep=false
    for want in "$@"; do [ "$k" != "$want" ] || keep=true; done
    [ "$keep" = true ] || rm -f -- "$f" || die "pruning the stale cached image $k"
  done
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

# each image is hit (pulled, and bound to the image under it), miss (not in the store) or stale
# (in the store, but thrown away: it is built again and pushed with --replace)
base=miss lyr=miss prep=miss
key="" lkey="" pkey=""

# spec: tests/main.bats -- every failure is named once, with its image (base, layer or prepared)
#       and its step: by space.sh, layer.sh (exit 1), boot.sh and snapshot.sh themselves, and here
#       for any other step, which fails without an ::error of its own
die() { echo "::error title=mavericks-vm::$1 failed"; exit 1; }

# spec: tests/main.bats -- a delta is bound to the bytes of the image under it, not to its key:
#       each image carries an image-id, made fresh when it is built, and each delta the image-id
#       of the image it was made over as its backing-id
id_in() {  # $1 = file; prints the id in it, or nothing
  local id
  id="$(cat "$1" 2>/dev/null)" || return 0
  [[ "$id" =~ ^[0-9a-f]{32}$ ]] && printf '%s' "$id"
  return 0
}

pull() {  # $1 = base, layer or prepared; $2 = its key; $3 = its dir; sets got to hit or miss
  step image.sh pull "$2" "$3"; rc=$?
  case "$rc" in 0) got=hit ;; 3) got=miss ;; *) die "pulling the $1 image" ;; esac
}
discard() {  # $1 = base, layer or prepared; $2 = its dir; $3 = why
  echo "mavericks-vm: the cached $1 image $3; making it again"
  rm -rf "$2" || die "removing the stale $1 image"
}

# spec: tests/main.bats -- room is checked before each download or build, never after
build_base() {
  step space.sh miss || exit 1
  step build.sh mavericks "$box" || die "building the base image"
  { od -An -N16 -tx1 /dev/urandom | tr -d ' \n'; echo; } > "$box/image-id" || die "recording the base image's image-id"
}
build_layer() {  # over the base in $box
  step space.sh layer || exit 1
  step layer.sh "$box" "$layer"; rc=$?
  case "$rc" in 0) ;; 1) exit 1 ;; *) die "building the layer image" ;; esac
}
# spec: tests/main.bats -- when another run cached its own image under a key first, this run's
#       push is skipped (image.sh exits 4) and this run's image is not in the store; whatever this
#       run made over it is bound to it, so it is not cached either (with --replace it would
#       overwrite one made over the cached image). This run still boots its own whole chain.
unstored=""
push() {  # $1 = base, layer or prepared (pushed in that order); $2 = its key; $3 = its dir; $4 = miss or stale
  if [ -n "$unstored" ]; then
    echo "mavericks-vm: not caching the $1 image: it was made over this run's $unstored image, which another run's took the place of in the cache"
    return
  fi
  if [ "$4" = stale ]; then
    step image.sh push --replace "$2" "$3" || die "pushing the $1 image"
  else
    step image.sh push "$2" "$3"; rc=$?
    case "$rc" in
      0) ;;
      4) unstored="$1"; return ;;
      *) die "pushing the $1 image" ;;
    esac
  fi
  pushed "$2"
}

want_prepared=false
if [ "${MVM_CACHE_AFTER_PREPARE:-false}" = true ] && [ -n "${MVM_PREPARE:-}" ]; then want_prepared=true; fi

# spec: tests/main.bats -- disable-cache builds the base and the layer, and pulls and pushes nothing
if [ "${MVM_DISABLE_CACHE:-false}" = true ]; then
  want_prepared=false
  build_base
  build_layer
else
  # spec: tests/main.bats -- with no prepare, the prepared guest is the layer guest: it is cached as
  #       the layer, and nothing is cached under a prepared key
  if [ "$want_prepared" = true ]; then
    pkey="$(MVM_PREPARE="${MVM_PREPARE:-}" step key.sh --prepared)" || die "computing the prepared image's key"
  fi
  lkey="$(step key.sh --layer)" || die "computing the layer image's key"
  key="$(step key.sh --base)" || die "computing the base image's key"
  top="${pkey:-$lkey}"
  if [ "$store" = file ]; then prune_blobs "$key" "$lkey" ${pkey:+"$pkey"}; fi
  step space.sh hit || exit 1
  if [ "$want_prepared" = true ]; then pull prepared "$pkey" "$prepared"; prep=$got; fi
  pull layer "$lkey" "$layer"; lyr=$got
  pull base "$key" "$box"; base=$got

  # spec: tests/main.bats -- an image is used only over the very image it was made over; one that
  #       is not is thrown away, from the bottom up and before anything is built (so the room it
  #       took is free when the builds' room is checked), and made again over what is here
  base_id="$(id_in "$box/image-id")"
  if [ "$base" = hit ] && [ -z "$base_id" ]; then
    discard base "$box" "has no image-id"; base=stale
  fi
  layer_id="$(id_in "$layer/image-id")"
  if [ "$lyr" = hit ]; then
    if [ "$base" != hit ]; then discard layer "$layer" "was made over a base image that is gone"; lyr=stale
    elif [ -z "$layer_id" ] || [ "$(id_in "$layer/backing-id")" != "$base_id" ]; then
      discard layer "$layer" "was not made over this base image"; lyr=stale
    fi
  fi
  if [ "$prep" = hit ]; then
    if [ "$lyr" != hit ]; then discard prepared "$prepared" "was made over a layer image that is gone"; prep=stale
    elif [ -z "$(id_in "$prepared/image-id")" ] || [ "$(id_in "$prepared/backing-id")" != "$layer_id" ]; then
      discard prepared "$prepared" "was not made over this layer image"; prep=stale
    fi
  fi

  if [ "$base" != hit ]; then build_base; push base "$key" "$box" "$base"; fi
  if [ "$lyr" != hit ]; then build_layer; push layer "$lkey" "$layer" "$lyr"; fi
fi
prepared_hit=false; [ "$prep" != hit ] || prepared_hit=true
echo "cache-after-prepare-hit=$prepared_hit" >> "${GITHUB_OUTPUT:-/dev/null}"

if [ "$prepared_hit" = true ]; then
  step boot.sh "$prepared" || exit 1
else
  step boot.sh "$layer" || exit 1
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
    step snapshot.sh "$layer" "$prepared" || exit 1
    push prepared "$pkey" "$prepared" "$prep"
    step boot.sh "$prepared" || exit 1
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
