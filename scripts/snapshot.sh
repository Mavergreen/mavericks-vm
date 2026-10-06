#!/bin/bash
# platform: GitHub's Linux runners only (bash, QEMU from apt, OpenSSH) -- this Action runs nowhere else
#   usage: snapshot.sh <box-dir> <out-dir>
#          env in:  MVM_DATA_DIR (holds overlay.qcow2 and qemu.pid); MVM_SHUTDOWN_TIMEOUT (default 180)
#          out:     <out-dir> holding the running guest's disk, flattened, and <box-dir>'s firmware;
#                   the guest powered off
set -euo pipefail

[ $# -eq 2 ] || { echo "usage: snapshot.sh <box-dir> <out-dir>" >&2; exit 2; }
box="$1"; out="$2"
data="${MVM_DATA_DIR:?snapshot.sh: MVM_DATA_DIR is unset}"
pid="$(cat "$data/qemu.pid")"

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
qemu-img convert -O qcow2 "$data/overlay.qcow2" "$out/box_0.img"
for f in OVMF_CODE.fd OVMF_VARS.fd opencore.img; do cp "$box/$f" "$out/$f"; done
echo "snapshot.sh: the prepared guest is in $out"
