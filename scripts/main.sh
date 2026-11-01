#!/bin/bash
# platform: GitHub's Linux runners only (bash) -- this Action runs nowhere else
#   usage: main.sh
#          env in:  MVM_* (scripts/inputs.sh), MVM_PREPARE, MVM_RUN, MVM_IMAGE_KEY, MVM_TOKEN;
#                   MVM_NO_HFSPLUS (install-tools.sh: the running kernel, when it has no hfsplus);
#                   MVM_BASE_RECIPE (optional: the plugin's base recipe, as action.yml's key step
#                   fetched it; when empty, key.sh fetches it here)
#          out:     run's exit status; in $GITHUB_OUTPUT, cache-after-prepare-hit, logs-dir (on a
#                   failure that kept logs: build.sh's, guest-logs.sh's, the boot's serial console) and, in the repo
#                   tier, cache-save-base, cache-save-layer and cache-save-prepared (true for each
#                   image this run stored); the guest left running for later "ssh mavericks" and
#                   custom-shell steps
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
data="${MVM_DATA_DIR:?main.sh: MVM_DATA_DIR is unset}"
# spec: tests/layer.bats "a base that is not the layer's sibling box is refused" -- siblings, so a
#       delta's relative backing file resolves: the layer's ../box/box_0.img and the prepared's
#       ../layer/box_0.img
box="$data/box" layer="$data/layer" prepared="$data/prepared"
mkdir -p "$data"
step() { bash "$here/$1" "${@:2}"; }
# spec: tests/main.bats -- where a failed step keeps what a person needs to read: under RUNNER_TEMP,
#       never data-dir, whose images this step removes; named in logs-dir for a workflow to upload
export MVM_LOG_DIR="${MVM_LOG_DIR:-${RUNNER_TEMP:-$data}/mavericks-vm-logs}"
store="${MVM_STORE:-registry}"

# spec: docs/superpowers/specs/2026-10-06-mavericks-vm-design.md "Two tiers" (in
#       packer-plugin-macosx) -- the repo tier keeps an actions/cache entry per image, so a change
#       that moves only the layer, or only prepare, never saves the ~6 GB base (or the layer) again.
#       After each successful push this says which image was stored (cache-save-base, -layer or
#       -prepared) for action.yml's save steps, so a failing run still keeps what it stored. A push
#       that was skipped, and a run that stored nothing, name nothing.
pushed() {  # $1 = base, layer or prepared: the image just stored
  if [ "$store" = file ]; then echo "cache-save-$1=true" >> "${GITHUB_OUTPUT:-/dev/null}"; fi
}

# spec: tests/main.bats -- the repo tier keeps only this run's set: every <64-hex>.tar.zst.age in
#       the blob dir that is none of this run's keys is deleted, so a restored set's stale members
#       free their disk before anything is pulled or built, and a failing run never saves them;
#       anything else in the dir is left alone
prune_blobs() {  # $@ = this run's keys
  local f k keep want
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

# spec: tests/main.bats -- an artifact is readable by anyone who can read the repo, and GitHub
#       masks a secret only in the job's log, so a kept file holding the image key or the token
#       is dropped before the dir is named
# shellcheck disable=SC2317  # keep_logs runs from finish, the EXIT trap's
keep_logs() {
  local f s
  if [ -f "$data/serial.log" ]; then mkdir -p "$MVM_LOG_DIR" && cp "$data/serial.log" "$MVM_LOG_DIR/boot-serial.log"; fi
  [ -d "$MVM_LOG_DIR" ] && [ -n "$(find "$MVM_LOG_DIR" -type f 2>/dev/null)" ] || return 0
  for s in "${MVM_IMAGE_KEY:-}" "${MVM_TOKEN:-}"; do
    [ -n "$s" ] || continue
    while IFS= read -r f; do
      rm -f -- "$f" && echo "mavericks-vm: dropped ${f#"$MVM_LOG_DIR"/} from the kept logs: it holds a secret"
    done < <(grep -rlF -e "$s" "$MVM_LOG_DIR" 2>/dev/null)
  done
  echo "logs-dir=$MVM_LOG_DIR" >> "${GITHUB_OUTPUT:-/dev/null}"
  echo "mavericks-vm: this run's logs are kept in $MVM_LOG_DIR (the step's logs-dir output)"
}

# shellcheck disable=SC2317  # finish runs from the EXIT trap below
finish() {
  status=$1
  if [ "$status" -ne 0 ] && [ "${MVM_DEBUG_ON_ERROR:-false}" = true ]; then
    echo "::group::mavericks-vm: the guest's system.log and serial console"
    ssh -F "$HOME/.ssh/config" mavericks 'tail -n 100 /var/log/system.log' 2>&1 || true
    tail -n 40 "$data/serial.log" 2>/dev/null || true
    echo "::endgroup::"
  fi
  if [ "$status" -ne 0 ]; then keep_logs; fi
  # spec: docs/superpowers/specs/2026-10-06-mavericks-vm-design.md "Safety" -- the decrypted guest
  #       leaves the disk when the step ends; a running QEMU keeps the files it has open, so later
  #       steps' ssh and custom shell still work (a composite action has no post step to do this)
  find "$box" "$layer" "$prepared" -mindepth 1 -delete 2>/dev/null || true
  # spec: tests/safety.bats -- defence in depth: layer.sh or build.sh killed on its own skips its own
  #       cleanup, so the full layer guest it decrypted and build.sh's work dir (packer's output) go
  #       here too (a SIGKILL of the whole step runs no cleanup at all, this one included)
  rm -rf "$data/layer-full" "$data/build" 2>/dev/null || true
  exit "$status"
}
trap 'finish $?' EXIT

# spec: tests/main.bats "a layer hit with a base miss" -- each image is hit (pulled, and bound to the
#       image under it), miss (not in the store) or stale (in the store, but thrown away: it is
#       built again and pushed with --replace)
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
  # spec: tests/main.bats -- the base image's installer media is built in the plugin's microVM,
  #       which loads hfsplus into the running kernel; install-tools.sh found none to load
  #       (MVM_NO_HFSPLUS), so the build would fail late, mounting the installer: it stops here
  if [ -n "${MVM_NO_HFSPLUS:-}" ]; then
    echo "::error title=mavericks-vm::building the base image needs the hfsplus module for the plugin's media microVM, and install-tools.sh found none for the running kernel, $MVM_NO_HFSPLUS (its warning says why); booting another kernel takes a packer-plugin-macosx release with privops' kernel choice (chooseRelease), which the pinned one is not"
    exit 1
  fi
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
  pushed "$1"
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
  # spec: tests/main.bats -- the base recipe is fetched once; key.sh uses it from the environment
  MVM_BASE_RECIPE="$(step key.sh --recipe)" || die "fetching the base recipe"
  export MVM_BASE_RECIPE
  if [ "$want_prepared" = true ]; then
    pkey="$(MVM_PREPARE="${MVM_PREPARE:-}" step key.sh --prepared)" || die "computing the prepared image's key"
  fi
  lkey="$(step key.sh --layer)" || die "computing the layer image's key"
  key="$(step key.sh --base)" || die "computing the base image's key"
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
