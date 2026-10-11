#!/bin/bash
# platform: GitHub's Linux runners only (bash, QEMU from apt, OpenSSH) -- this Action runs nowhere else
#   usage: snapshot.sh <box-dir> <out-dir>
#          env in:  MVM_DATA_DIR (holds overlay.qcow2 and qemu.pid); MVM_SHUTDOWN_TIMEOUT (default 180)
#          in:      <box-dir>, the layer guest that booted, with its image-id, which must be
#                   <out-dir>/../layer
#          out:     <out-dir> holding the running guest's disk as box_0.img, a qcow2 delta whose
#                   backing file is the literal ../layer/box_0.img, <box-dir>'s firmware, image-id
#                   (fresh: 32 hex digits) and backing-id (<box-dir>'s image-id); the guest powered off
set -euo pipefail

[ $# -eq 2 ] || { echo "usage: snapshot.sh <box-dir> <out-dir>" >&2; exit 2; }
box="$1"; out="$2"
data="${MVM_DATA_DIR:?snapshot.sh: MVM_DATA_DIR is unset}"
pid="$(cat "$data/qemu.pid")"

# spec: tests/snapshot.bats -- a delta is bound to the bytes of the image under it: the prepared
#       image records the layer's image-id; a layer without one is refused while the guest still runs
layer_id="$(cat "$box/image-id" 2>/dev/null || true)"
if ! [[ "$layer_id" =~ ^[0-9a-f]{32}$ ]]; then
  echo "::error title=mavericks-vm::snapshotting the prepared image: the layer has no image-id in $box/image-id to bind it to"
  exit 1
fi

ssh -F "$HOME/.ssh/config" mavericks 'sudo shutdown -h now' > /dev/null 2>&1 || true
# spec: tests/snapshot.bats -- a disk copied while the guest still runs is not a guest anyone can boot
waited=0; limit="${MVM_SHUTDOWN_TIMEOUT:-180}"
while kill -0 "$pid" 2>/dev/null; do
  if [ "$waited" -ge "$limit" ]; then
    echo "::error title=mavericks-vm::the guest did not power off within ${limit}s; not caching a running disk"
    exit 1
  fi
  sleep 1; waited=$((waited + 1))
done

mkdir -p "$out"
# spec: tests/snapshot.bats -- run in <out-dir> so the relative backing file is stored as written;
#       it resolves because the prepared dir is the layer dir's sibling in data-dir
(cd "$out" && qemu-img convert -O qcow2 -F qcow2 -B ../layer/box_0.img "$data/overlay.qcow2" box_0.img)
for f in OVMF_CODE.fd OVMF_VARS.fd opencore.img; do cp "$box/$f" "$out/$f"; done
od -An -N16 -tx1 /dev/urandom | tr -d ' \n' > "$out/image-id"; echo >> "$out/image-id"
printf '%s\n' "$layer_id" > "$out/backing-id"
echo "snapshot.sh: the prepared guest is in $out"
