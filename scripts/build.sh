#!/bin/bash
# platform: GitHub's Linux runners only (bash, GNU tar, curl, unzip) -- this Action runs nowhere else
#   usage: build.sh <dir>
#          env in:  MVM_DATA_DIR, MVM_CACHE_DIR
#          out:     the guest's box contents (box_0.img, OVMF_CODE.fd, OVMF_VARS.fd, opencore.img,
#                   ...) in <dir>; on failure, the end of packer's output and exit 1
set -euo pipefail

[ $# -eq 1 ] || { echo "usage: build.sh <dir>" >&2; exit 2; }
out="$1"
root="$(cd "$(dirname "$0")/.." && pwd)"
pin="$(tr -d '[:space:]' < "$root/components/packer-plugin-macosx/version")"
data="${MVM_DATA_DIR:?build.sh: MVM_DATA_DIR is unset}"
work="$data/build"
mkdir -p "$work" "${MVM_CACHE_DIR:?build.sh: MVM_CACHE_DIR is unset}"

zip="packer-plugin-macosx_${pin}_mavericks_template.zip"
curl -fsSL --retry 3 -o "$work/$zip" \
  "https://github.com/Mavergreen/packer-plugin-macosx/releases/download/$pin/$zip"
(cd "$work" && unzip -q -o "$zip")
tpl="$work/templates/mavericks"

export PACKER_PLUGIN_PATH="$data/packer-plugins" PACKER_CACHE_DIR="$MVM_CACHE_DIR" CHECKPOINT_DISABLE=1
# spec: tests/build.bats -- exactly the pinned plugin, installed before init: init alone would
#       take the newest release its ~> constraint allows, which may be newer than the cache key says
packer plugins install github.com/mavergreen/macosx "$pin" > /dev/null
(cd "$tpl" && packer init . > /dev/null)

log="$work/packer-build.log"
if ! (cd "$tpl" && packer build -var-file="$root/box.pkrvars.hcl" .) > "$log" 2>&1; then
  echo "::error title=mavericks-vm::building the guest with packer-plugin-macosx $pin failed; the end of packer's output:"
  tail -n 40 "$log"
  exit 1
fi

box="$(ls "$tpl"/output/*.box)"
mkdir -p "$out"
tar -xzf "$box" -C "$out"
# spec: tests/build.bats -- the guest leaves the disk when the step ends: packer's output (the box,
#       and the image it was made from) goes as soon as the box is unpacked into <dir>, which
#       main.sh's own cleanup covers
find "$work" -mindepth 1 -delete
echo "build.sh: built the guest with packer-plugin-macosx $pin"
