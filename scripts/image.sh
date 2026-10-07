#!/bin/bash
# platform: GitHub's Linux runners only (bash, GNU tar, zstd) -- this Action runs nowhere else
#   usage: image.sh pull <key> <dir>    0: the guest is in <dir>; 3: no guest under <key>
#          image.sh push <key> <dir>    0: pushed, or already there
#          env in:  MVM_IMAGE_KEY (an age identity), MVM_STORE (registry | file), MVM_BLOB_DIR (the
#                   file store's directory: <key>.tar.zst.age), MVM_TOKEN, GITHUB_ACTOR,
#                   MVM_REGISTRY, MVM_DATA_DIR
set -euo pipefail

usage() { echo "usage: image.sh pull|push <64-hex key> <dir>" >&2; exit 2; }
[ $# -eq 3 ] || usage
cmd="$1"; key="$2"; dir="$3"
case "$cmd" in pull|push) ;; *) usage ;; esac
[[ "$key" =~ ^[0-9a-f]{64}$ ]] || usage
: "${MVM_IMAGE_KEY:?image.sh: MVM_IMAGE_KEY is empty}"
registry="${MVM_REGISTRY:-ghcr.io/mavergreen/mavericks-vm-images}"
ref="$registry:$key"
work="$(mktemp -d "${MVM_DATA_DIR:-${TMPDIR:-/tmp}}/image.XXXXXX" 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/image.XXXXXX")"
trap 'rm -rf "$work"' EXIT

store="${MVM_STORE:-registry}"
blob="${MVM_BLOB_DIR:+$MVM_BLOB_DIR/$key.tar.zst.age}"
# spec: tests/image.bats -- the token and the key reach their programs on stdin, never argv:
#       printf is a bash builtin, so neither is ever a process argument
if [ "$store" = registry ]; then
  printf '%s' "${MVM_TOKEN:-}" | oras login "${registry%%/*}" -u "${GITHUB_ACTOR:-mavericks-vm}" --password-stdin > /dev/null
else
  : "${blob:?image.sh: MVM_BLOB_DIR is empty for the file store}"
fi

# spec: docs/superpowers/specs/2026-10-06-mavericks-vm-design.md "Two tiers" (in
#       packer-plugin-macosx) -- the file store is one encrypted file that actions/cache restores
#       and saves; this script only encrypts into it and decrypts out of it
exists() {
  if [ "$store" = file ]; then [ -s "$blob" ]; return; fi
  local err
  if err="$(oras manifest fetch "$ref" 2>&1 > /dev/null)"; then return 0; fi
  case "$err" in *"not found"*|*"manifest unknown"*|*"MANIFEST_UNKNOWN"*) return 1 ;; esac
  echo "image.sh: could not tell whether $ref exists: $err" >&2
  exit 1
}

# spec: tests/image.bats -- GHCR cut three jobs' 6.8 GB downloads off at once mid-transfer
#       ("stream error ... PROTOCOL_ERROR; received from peer") while a fourth, the same minute, went
#       through (Actions run 37620368526); a dropped transfer is tried twice more before it fails
# spec: tests/image.bats -- and each attempt has a time limit (MVM_TRANSFER_TIMEOUT, 1800 s): a
#       transfer that stalls without failing is cut off and tried again
tries() {  # $@ = the transfer; 3 attempts, waiting MVM_RETRY_WAIT (default 20) s, then twice that
  local n=1 wait="${MVM_RETRY_WAIT:-20}" limit="${MVM_TRANSFER_TIMEOUT:-1800}" rc
  until timeout "$limit" "$@"; do
    rc=$?
    [ "$rc" -ne 124 ] || echo "image.sh: attempt $n of 3 did not finish in ${limit}s" >&2
    [ "$n" -lt 3 ] || return 1
    echo "image.sh: attempt $n of 3 failed; trying again in $((wait * n))s" >&2
    sleep $((wait * n)); n=$((n + 1))
  done
}

if [ "$cmd" = pull ]; then
  exists || { echo "image.sh: no cached guest under $key"; exit 3; }
  if [ "$store" = file ]; then cp "$blob" "$work/box.tar.zst.age"; else tries oras pull "$ref" -o "$work" > /dev/null; fi
  mkdir -p "$work/unpacked"
  # spec: tests/image.bats -- age authenticates what it decrypts, so a corrupt or foreign blob
  #       fails here; the guest reaches <dir> only once all of it has decrypted and unpacked
  if ! printf '%s\n' "$MVM_IMAGE_KEY" | age -d -i - -o - "$work/box.tar.zst.age" \
       | zstd -d -q | tar -x -C "$work/unpacked"; then
    # spec: tests/image.bats -- in this repo's own cache, a guest that will not decrypt (most often:
    #       the repo's key was changed) is a miss; the blob goes, so the rebuilt guest's push
    #       replaces it, and action.yml saves that under a newer name for restore to prefer
    if [ "$store" = file ]; then
      echo "image.sh: the cached guest under $key did not decrypt and unpack (corrupt, or encrypted for another key); building it again" >&2
      rm -f -- "$blob"
      exit 3
    fi
    echo "image.sh: the cached guest under $key did not decrypt and unpack (corrupt, truncated, or encrypted for another key)" >&2
    exit 1
  fi
  mkdir -p "$dir"
  find "$work/unpacked" -mindepth 1 -maxdepth 1 -exec mv -t "$dir" {} +
  echo "image.sh: pulled the cached guest $key"
else
  if exists; then echo "image.sh: a guest is already cached under $key; not pushing"; exit 0; fi
  recipient="$(printf '%s\n' "$MVM_IMAGE_KEY" | age-keygen -y)"
  tar -C "$dir" -cf - . | zstd -q -T0 -10 --long=27 | age -r "$recipient" -o "$work/box.tar.zst.age"
  if exists; then echo "image.sh: a guest appeared under $key meanwhile; not pushing"; exit 0; fi
  if [ "$store" = file ]; then
    mkdir -p "$(dirname "$blob")" && mv "$work/box.tar.zst.age" "$blob"
  else
    (cd "$work" && tries oras push "$ref" "box.tar.zst.age:application/vnd.mavergreen.mavericks-vm.box.v1+age" > /dev/null)
  fi
  echo "image.sh: pushed the cached guest $key"
fi
