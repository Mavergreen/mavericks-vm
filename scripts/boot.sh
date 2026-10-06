#!/bin/bash
# platform: GitHub's Linux runners only (bash, QEMU from apt, OpenSSH) -- this Action runs nowhere else
#   usage: boot.sh <dir>     <dir> holds the box: box_0.img, OVMF_CODE.fd, OVMF_VARS.fd, opencore.img
#          env in:  MVM_DATA_DIR, MVM_MEM, MVM_CPU, MVM_CPU_MODEL, MVM_NAT; MVM_KVM, MVM_SSH_PORT,
#                   MVM_SSH_TIMEOUT, MVM_SSH_INTERVAL (defaults: /dev/kvm, 2222, 600, 5)
#          out:     the guest running, and "ssh mavericks" reaching it
set -euo pipefail

[ $# -eq 1 ] || { echo "usage: boot.sh <dir>" >&2; exit 2; }
box="$1"
root="$(cd "$(dirname "$0")/.." && pwd)"
data="${MVM_DATA_DIR:?boot.sh: MVM_DATA_DIR is unset}"
kvm="${MVM_KVM:-/dev/kvm}"
port="${MVM_SSH_PORT:-2222}"
mkdir -p "$data"

[ -w "$kvm" ] || { echo "::error title=mavericks-vm::$kvm is not writable: this runner cannot run KVM, and Mavericks under plain emulation is too slow to be worth waiting for"; exit 1; }
for f in box_0.img OVMF_CODE.fd OVMF_VARS.fd opencore.img; do
  [ -f "$box/$f" ] || { echo "::error title=mavericks-vm::the cached guest has no $f"; exit 1; }
done

overlay="$data/overlay.qcow2"
qemu-img create -f qcow2 -F qcow2 -b "$box/box_0.img" "$overlay" > /dev/null

fwd="hostfwd=tcp:127.0.0.1:$port-:22"
for n in ${MVM_NAT:-}; do
  IFS=: read -r proto hp gp <<< "$n"
  fwd="$fwd,hostfwd=$proto::$hp-:$gp"
done

# spec: packer-plugin-macosx templates/mavericks/box.Vagrantfile.pkrtpl -- the box's own machine:
#       q35 with EHCI and UHCI companions (10.9 cannot drive XHCI), OpenCore on usb-storage, the
#       disk on IDE, e1000, VGA; the disk here is an overlay, so the cached image never changes
qemu-system-x86_64 \
  -name mavericks-vm -machine q35,vmport=off,accel=kvm \
  -cpu "${MVM_CPU_MODEL:?}" -m "${MVM_MEM:?}M" -smp "${MVM_CPU:?}" -parallel none \
  -drive "if=pflash,format=raw,unit=0,readonly=on,file=$box/OVMF_CODE.fd" \
  -drive "if=pflash,format=raw,unit=1,snapshot=on,file=$box/OVMF_VARS.fd" \
  -device ich9-usb-ehci1,id=usb,bus=pcie.0,addr=0x1d.7,multifunction=on \
  -device ich9-usb-uhci1,masterbus=usb.0,firstport=0,bus=pcie.0,addr=0x1d.0,multifunction=on \
  -device ich9-usb-uhci2,masterbus=usb.0,firstport=2,bus=pcie.0,addr=0x1d.1 \
  -device ich9-usb-uhci3,masterbus=usb.0,firstport=4,bus=pcie.0,addr=0x1d.2 \
  -drive "id=opencore,if=none,format=raw,snapshot=on,file=$box/opencore.img" \
  -device usb-storage,bus=usb.0,drive=opencore \
  -drive "id=target,if=none,format=qcow2,file=$overlay" \
  -device ide-hd,bus=ide.0,drive=target \
  -netdev "user,id=net0,$fwd" -device e1000-82545em,netdev=net0 \
  -device usb-kbd,bus=usb.0 -device usb-mouse,bus=usb.0 -device VGA,vgamem_mb=64 \
  -display none -serial "file:$data/serial.log" -daemonize -pidfile "$data/qemu.pid"

install -m 0600 "$root/scripts/vagrant-insecure.key" "$data/ssh-key"
mkdir -p "$HOME/.ssh"; chmod 0700 "$HOME/.ssh"
cat >> "$HOME/.ssh/config" <<SSHCONFIG

Host mavericks
  HostName 127.0.0.1
  Port $port
  User vagrant
  IdentityFile $data/ssh-key
  IdentitiesOnly yes
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  LogLevel ERROR
  ConnectTimeout 10
SSHCONFIG

waited=0; limit="${MVM_SSH_TIMEOUT:-600}"; every="${MVM_SSH_INTERVAL:-5}"
# platform: OpenSSH reads ~/.ssh/config from the passwd entry's home, not $HOME, so every ssh
#           this Action runs names the file it wrote (measured 2026-10-06: with HOME elsewhere, a
#           bare "ssh mavericks" never found the host)
until ssh -F "$HOME/.ssh/config" mavericks true 2>/dev/null; do
  if [ "$waited" -ge "$limit" ]; then
    echo "::error title=mavericks-vm::the guest did not answer SSH within ${limit}s; the end of its serial log:"
    tail -n 40 "$data/serial.log" 2>/dev/null || echo "(no serial log)"
    exit 1
  fi
  sleep "$every"; waited=$((waited + every))
done
echo "boot.sh: the guest answered SSH after ${waited}s"
