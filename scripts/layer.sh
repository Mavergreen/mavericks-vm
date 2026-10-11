#!/bin/bash
# platform: GitHub's Linux runners only (bash, GNU coreutils, QEMU from apt) -- this Action runs nowhere else
#   usage: layer.sh <base-dir> <layer-dir>
#          env in:  MVM_DATA_DIR, MVM_CACHE_DIR (for build.sh)
#          in:      <base-dir>, the unpacked base guest, which must be <layer-dir>/../box; never written
#          out:     <layer-dir> holding box_0.img, a qcow2 delta whose backing file is the literal
#                   ../box/box_0.img, and the layer build's OVMF_CODE.fd, OVMF_VARS.fd, opencore.img;
#                   on failure, nothing this run made (and an <layer-dir> must be absent or empty), no $MVM_DATA_DIR/layer-full, and exit 1
set -euo pipefail

[ $# -eq 2 ] || { echo "usage: layer.sh <base-dir> <layer-dir>" >&2; exit 2; }
base="$1"; layer="$2"
here="$(cd "$(dirname "$0")" && pwd)"
data="${MVM_DATA_DIR:?layer.sh: MVM_DATA_DIR is unset}"
full="$data/layer-full"

# spec: tests/layer.bats -- the delta's backing file is the relative string ../box/box_0.img, which
#       resolves only when the base is the layer's sibling named box
if [ "$(realpath -m "$base")" != "$(realpath -m "$layer/../box")" ]; then
  echo "layer.sh: <base-dir> must be <layer-dir>/../box so the delta's backing ../box/box_0.img resolves; got $base and $layer" >&2
  exit 2
fi

# spec: tests/layer.bats -- a layer dir that is not empty is somebody's; refuse before touching it
if [ -n "$(ls -A "$layer" 2>/dev/null)" ]; then
  echo "layer.sh: <layer-dir> $layer is not empty; refusing to write over it" >&2
  exit 2
fi
made=false; [ -e "$layer" ] || made=true

# spec: tests/layer.bats -- the decrypted full image leaves the disk however this ends, and a partial
#       layer dir is never left looking complete
ok=false
cleanup() {
  rm -rf "$full"
  if [ "$ok" != true ]; then  # remove only what this run made
    if [ "$made" = true ]; then rm -rf "$layer"; else find "$layer" -mindepth 1 -delete 2>/dev/null || true; fi
  fi
}
trap cleanup EXIT
# spec: tests/layer.bats -- the exact error line is the one the brief names; build.sh's own lines precede it
bash "$here/build.sh" mavericks-aquatransport "$full" "$base" \
  || { echo "::error title=mavericks-vm::building the Aqua Transport layer"; exit 1; }

mkdir -p "$layer"
# spec: tests/layer.bats -- run in the layer dir so the relative backing file is stored as written
(cd "$layer" && qemu-img convert -O qcow2 -F qcow2 -B ../box/box_0.img "$full/box_0.img" box_0.img) \
  || { echo "::error title=mavericks-vm::building the Aqua Transport layer"; echo "layer.sh: writing the delta over the base failed" >&2; exit 1; }
for f in OVMF_CODE.fd OVMF_VARS.fd opencore.img; do
  cp "$full/$f" "$layer/$f" \
    || { echo "::error title=mavericks-vm::building the Aqua Transport layer"; echo "layer.sh: copying $f failed" >&2; exit 1; }
done
ok=true
echo "layer.sh: the Aqua Transport layer is in $layer"
