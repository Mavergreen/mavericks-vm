#!/bin/bash
# platform: GitHub's Linux runners only (bash, passwordless sudo, qemu-nbd, the hfsplus module) -- this Action runs nowhere else
#   usage: guest-logs.sh <template-dir> <work-dir> <dest>
#          guest-logs.sh copy <volume-root> <dest>
#          after a failed packer build (-on-error=abort): keeps in <dest> packer's output and debug
#          log (<work-dir>/packer-build.log, packer-debug.log), the guest's serial console (the
#          template's output-*-install.log), and the guest's own logs, read offline from the disk
#          packer left in <template-dir>/output-*/, with summary.txt saying what was kept and what
#          could not be. Never the disk, the box or any other file of the guest's. Exits 0: what
#          it cannot keep it says, and the build's failure stays the step's verdict.
#          copy: the guest's logs only, from a volume already mounted at <volume-root>.
set -uo pipefail

# spec: tests/guest_logs.bats -- what leaves the guest, by path under its volume, each at most
#       its last 16 MiB
CAP=$((16 * 1024 * 1024))
GUEST_LOGS=(
  ".guest-macosx-firstboot.log" ".guest-macosx-autoinstall.log"
  "private/var/log/*.log" "private/var/log/*.crash"
  "private/var/db/.guest-macosx-firstboot/*"
  "Library/Logs/DiagnosticReports/*" "Users/*/Library/Logs/DiagnosticReports/*"
)

copy() {  # $1 = volume root, $2 = dest
  local root="$1" dest="$2" pat base depth f rel
  mkdir -p "$dest" || return 1
  for pat in "${GUEST_LOGS[@]}"; do
    # platform: the volume's files are root's (system.log is 640 root:admin), so they are listed
    #           and read through sudo; find from the pattern's fixed directory, at its depth alone
    base="${pat%%\**}"; base="${base%/*}"
    [ "$base" != "${pat%%\**}" ] || base=""
    depth="$(tr -cd / <<< "${pat#"$base"}" | wc -c)"
    [ -n "$base" ] || depth=$((depth + 1))
    while IFS= read -r -d '' f; do
      rel="${f#"$root"/}"
      # shellcheck disable=SC2024  # the file is ours, written as us; only the read is root's
      sudo tail -c "$CAP" -- "$f" > "$dest/${rel//\//_}" || rm -f "$dest/${rel//\//_}"
    done < <(sudo find "$root${base:+/$base}" -mindepth "$depth" -maxdepth "$depth" -path "$root/$pat" -type f -print0 2>/dev/null)
  done
}

if [ "${1:-}" = copy ]; then
  [ $# -eq 3 ] || { echo "usage: guest-logs.sh copy <volume-root> <dest>" >&2; exit 2; }
  copy "$2" "$3"; exit $?
fi
[ $# -eq 3 ] || { echo "usage: guest-logs.sh <template-dir> <work-dir> <dest>" >&2; exit 2; }
tpl="$1" work="$2" dest="$3"
mkdir -p "$dest" || exit 0
summary="$dest/summary.txt"
say() { printf '%s\n' "$*" >> "$summary"; }

for f in packer-build.log packer-debug.log; do
  if [ -f "$work/$f" ]; then cp "$work/$f" "$dest/$f"; else say "no $f"; fi
done
serial=0
for f in "$tpl"/output-*-install.log; do
  [ -f "$f" ] || continue
  cp "$f" "$dest/serial-$(basename "$f")" && serial=1
done
[ "$serial" = 1 ] || say "no serial console (output-*-install.log) in $tpl"

# spec: tests/guest_logs.bats -- packer -on-error=abort leaves its QEMU running on the disk; only
#       the pid packer logged, and only when that pid is a QEMU, is stopped
pid="$(sed -n 's/.*Started Qemu\. Pid: \([0-9][0-9]*\).*/\1/p' "$work/packer-debug.log" 2>/dev/null | tail -n 1)"
if [ -n "$pid" ]; then
  if [[ "$(cat "/proc/$pid/comm" 2>/dev/null)" == qemu-system-* ]]; then
    # platform: /proc/<pid>/stat fields 3 (state), 14-15 (utime, stime) and 22 (start) in clock ticks;
    #           the command name is in parentheses and may hold spaces, so fields count after it
    ticks="$(getconf CLK_TCK 2>/dev/null || echo 100)"
    # shellcheck disable=SC2046  # the fields are words
    set -- $(sed 's/^.*) //' "/proc/$pid/stat" 2>/dev/null)
    up="$(cut -d. -f1 /proc/uptime 2>/dev/null)"
    if [ $# -ge 20 ] && [ -n "$up" ]; then
      age=$((up - ${20} / ticks))
      cpu="$(awk -v t="$((${12} + ${13}))" -v k="$ticks" 'BEGIN { printf "%.1f", t / k }')"
      say "qemu (pid $pid): state $1, $cpu s of CPU in $age s ($(awk -v c="$cpu" -v a="$((age > 0 ? age : 1))" 'BEGIN { printf "%.0f", 100 * c / a }')% of one core), kept running until now"
    else
      say "qemu (pid $pid): its /proc stat could not be read"
    fi
    kill "$pid" 2>/dev/null
    for _ in $(seq 1 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
    if kill -0 "$pid" 2>/dev/null; then say "the build's QEMU (pid $pid) did not stop"; else say "stopped the build's QEMU (pid $pid)"; fi
  else
    say "pid $pid is not a QEMU (anymore); left alone"
  fi
fi

disk="$(find "$tpl" -mindepth 2 -maxdepth 2 -path "$tpl/output-*/*.qcow2" -type f 2>/dev/null | head -n 1)"
if [ -z "$disk" ]; then
  say "offline read: no guest disk under $tpl/output-*/"
  exit 0
fi

# spec: tests/guest_logs.bats -- read-only all the way: qemu-nbd --read-only, mount -o ro
dev="" mnt="$(mktemp -d "${TMPDIR:-/tmp}/mavericks-vm-guest.XXXXXX")"
# shellcheck disable=SC2317  # cleanup runs from the EXIT trap below
cleanup() {
  sudo umount "$mnt" 2>/dev/null
  [ -z "$dev" ] || sudo qemu-nbd --disconnect "$dev" > /dev/null 2>&1
  rmdir "$mnt" 2>/dev/null
}
trap cleanup EXIT
offline() {  # sets why; returns 0 when the guest's logs were copied
  local p
  why="$(sudo modprobe nbd max_part=16 2>&1)" || { why="modprobe nbd: $why"; return 1; }
  for p in /sys/block/nbd*; do
    [ -e "$p/pid" ] || { dev="/dev/${p##*/}"; break; }
  done
  [ -n "$dev" ] || { why="no free nbd device"; return 1; }
  why="$(sudo qemu-nbd --read-only --format=qcow2 --connect="$dev" "$disk" 2>&1)" || { dev=""; why="qemu-nbd: $why"; return 1; }
  part=""
  for _ in $(seq 1 50); do
    for p in "$dev"p*; do
      [ -b "$p" ] || continue
      if [ "$(sudo blkid -o value -s TYPE "$p" 2>/dev/null)" = hfsplus ]; then part="$p"; break 2; fi
    done
    sleep 0.2
  done
  [ -n "$part" ] || { why="no HFS+ partition on $dev"; return 1; }
  why="$(sudo modprobe hfsplus 2>&1)" || { why="modprobe hfsplus: $why"; return 1; }
  why="$(sudo mount -t hfsplus -o ro,nodev,nosuid,noexec "$part" "$mnt" 2>&1)" || { why="mount $part: $why"; return 1; }
  copy "$mnt" "$dest/guest" || { why="copying the guest's logs failed"; return 1; }
  why="$(find "$dest/guest" -type f | wc -l) files from $part"
}
why=""
if offline; then
  say "offline read of $disk: $why"
else
  say "offline read: reading $disk failed: $why"
fi
exit 0
