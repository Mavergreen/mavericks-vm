#!/bin/bash
# platform: GitHub's Linux runners only (bash, GNU coreutils, QEMU from apt) -- this Action runs nowhere else
#   usage: layer.sh <base-dir> <layer-dir>
#          env in:  MVM_DATA_DIR, MVM_CACHE_DIR (for build.sh)
#          in:      <base-dir>, the unpacked base guest with its image-id, which must be
#                   <layer-dir>/../box; never written
#          out:     <layer-dir> holding box_0.img, a qcow2 delta whose backing file is the literal
#                   ../box/box_0.img, and the layer build's OVMF_CODE.fd, OVMF_VARS.fd, opencore.img;
#                   image-id (fresh: 32 hex digits) and backing-id (the base's image-id);
#                   on failure, nothing this run made (and an <layer-dir> must be absent or empty), no $MVM_DATA_DIR/layer-full, and exit 1
#                   after the one ::error naming the layer (exit 2: a usage error, not annotated)
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

# spec: tests/layer.bats -- a layer dir that is not empty is somebody's, and one that cannot be
#       listed is not known to be empty; refuse either before touching it
if [ -e "$layer" ]; then
  listing="$(ls -A "$layer")" || { echo "layer.sh: cannot read <layer-dir> $layer" >&2; exit 2; }
else
  listing=""
fi
if [ -n "$listing" ]; then
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
fail() {  # $1 = what failed, if known; the one ::error names the image and the step, as the others do
  if [ -n "${1:-}" ]; then
    echo "::error title=mavericks-vm::building the layer image: $1"
  else
    echo "::error title=mavericks-vm::building the layer image failed"
  fi
  exit 1
}

# spec: tests/layer.bats -- a delta is bound to the bytes of the image under it, not to its key:
#       the layer records the base's image-id as its backing-id, and an id of its own for a
#       prepared image to record; a base without one cannot be bound to, so nothing is built
base_id="$(cat "$base/image-id" 2>/dev/null || true)"
[[ "$base_id" =~ ^[0-9a-f]{32}$ ]] || fail "the base has no image-id in $base/image-id, so the layer cannot be bound to it"

# spec: tests/layer.bats -- a full image left by an earlier run is not built over or beside
rm -rf "$full" || fail "removing an earlier layer-full failed"
# build.sh's own lines precede the error line
bash "$here/build.sh" mavericks-aquatransport "$full" "$base" || fail

mkdir -p "$layer" || fail "making $layer failed"
# spec: tests/layer.bats -- run in the layer dir so the relative backing file is stored as written
(cd "$layer" && qemu-img convert -O qcow2 -F qcow2 -B ../box/box_0.img "$full/box_0.img" box_0.img) \
  || fail "writing the delta over the base failed"
for f in OVMF_CODE.fd OVMF_VARS.fd opencore.img; do
  cp "$full/$f" "$layer/$f" \
    || fail "copying $f failed"
done
layer_id="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')" || fail "making the layer's image-id failed"
{ printf '%s\n' "$layer_id" > "$layer/image-id" && printf '%s\n' "$base_id" > "$layer/backing-id"; } \
  || fail "writing the layer's image-id and backing-id failed"
ok=true
echo "layer.sh: the Aqua Transport layer is in $layer"
