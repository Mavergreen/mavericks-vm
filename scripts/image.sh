#!/bin/bash
# platform: GitHub's Linux runners only (bash, GNU tar, zstd) -- this Action runs nowhere else
#   usage: image.sh pull <key> <dir>    0: the guest is in <dir>; 3: no guest under <key>
#          image.sh push <key> <dir>    0: pushed, or already there
#          env in:  MVM_IMAGE_KEY (an age identity), MVM_TOKEN, GITHUB_ACTOR, MVM_REGISTRY,
#                   MVM_DATA_DIR
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

# spec: tests/image.bats -- the token and the key reach their programs on stdin, never argv:
#       printf is a bash builtin, so neither is ever a process argument
printf '%s' "${MVM_TOKEN:-}" | oras login "${registry%%/*}" -u "${GITHUB_ACTOR:-mavericks-vm}" --password-stdin > /dev/null

exists() {
  local err
  if err="$(oras manifest fetch "$ref" 2>&1 > /dev/null)"; then return 0; fi
  case "$err" in *"not found"*|*"manifest unknown"*|*"MANIFEST_UNKNOWN"*) return 1 ;; esac
  echo "image.sh: could not tell whether $ref exists: $err" >&2
  exit 1
}

if [ "$cmd" = pull ]; then
  exists || { echo "image.sh: no cached guest under $key"; exit 3; }
  oras pull "$ref" -o "$work" > /dev/null
  mkdir -p "$work/unpacked"
  # spec: tests/image.bats -- age authenticates what it decrypts, so a corrupt or foreign blob
  #       fails here; the guest reaches <dir> only once all of it has decrypted and unpacked
  if ! printf '%s\n' "$MVM_IMAGE_KEY" | age -d -i - -o - "$work/box.tar.zst.age" \
       | zstd -d -q | tar -x -C "$work/unpacked"; then
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
  (cd "$work" && oras push "$ref" "box.tar.zst.age:application/vnd.mavergreen.mavericks-vm.box.v1+age" > /dev/null)
  echo "image.sh: pushed the cached guest $key"
fi
