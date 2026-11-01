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

# spec: tests/guest_logs.bats -- Actions run 41318225783 (build 15): scp -vt /tmp exited 1 with nothing on
#       stderr, 151 times in 5 minutes, against a guest whose sshd had accepted the key; the logs
#       on its disk could not say why. While the QEMU is still up, one bounded ssh as the template's
#       own user and (public, first-boot-only) key runs read-only questions of the live guest:
#       who it is, /tmp, what runs, its system.log, and the very scp packer ran, fed nothing.
live_guest() {  # $1 = the QEMU's pid; writes $dest/live-guest.txt, and says in the summary what happened
  local port key rc
  port="$(sed -n 's/.*Attempting SSH connection to 127\.0\.0\.1:\([0-9][0-9]*\)\.\.\..*/\1/p' "$work/packer-debug.log" 2>/dev/null | tail -n 1)"
  key="$(find "$tpl" -maxdepth 1 -name "*first-boot-only.key.rsa" 2>/dev/null | head -n 1)"
  if [ -z "$port" ] || [ -z "$key" ]; then say "live guest: no ssh port ('${port:-}') or key ('${key:-}') to ask it with"; return 0; fi
  install -m 0600 "$key" "$work/live-key" 2>/dev/null || { say "live guest: cannot copy the key"; return 0; }
  timeout "${GUEST_LOGS_LIVE_TIMEOUT:-150}" ssh -o BatchMode=yes -o ConnectTimeout=20 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR -i "$work/live-key" -p "$port" vagrant@127.0.0.1 'sh -s' > "$dest/live-guest.txt" 2>&1 <<'LIVE'
exec 2>&1
echo "== who, when: $(id) / $(date) / $(uname -a)"
echo "== uptime"; uptime
echo "== /tmp, home, disk"; ls -ldO /tmp /private/tmp /Users/vagrant; [ -w /tmp ] && echo "/tmp: writable" || echo "/tmp: NOT writable"; df -h /
echo "== shell, scp"; echo "shell: $SHELL"; command -v scp; ls -l "$(command -v scp)"
echo "== scp -vt /tmp, fed nothing (what packer runs)"; scp -vt /tmp < /dev/null; echo "scp rc=$?"
echo "== processes"; ps -axo pid,ppid,stat,etime,command | head -n 80
echo "== launchd jobs"; launchctl list | head -n 80
echo "== system.log (last 80)"; tail -n 80 /var/log/system.log
exit 0
LIVE
  rc=$?
  say "live guest: asked it over ssh on port $port (exit $rc), answer in live-guest.txt ($(wc -l < "$dest/live-guest.txt") lines)"
  live_ssh_variants "$port"
  rm -f "$work/live-key"
}

# spec: Actions run 41353051295 (builds 7 and 38) -- see tests/guest_logs.bats: which part of an sshd session
#       fails, told apart by a few more bounded sessions with ssh's own -vvv (the last 60 lines of each)
live_ssh_variants() {  # $1 = the port; writes $dest/live-ssh.txt
  local port="$1" out="$dest/live-ssh.txt" t="${GUEST_LOGS_LIVE_TIMEOUT:-150}" rc
  local opts=(-vvv -o BatchMode=yes -o ConnectTimeout=20 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$work/live-key" -p "$port")
  : > "$out"
  variant() {  # $1 = label, then the ssh arguments after the host
    local label="$1" log; shift
    log="$(mktemp "${TMPDIR:-/tmp}/live-ssh.XXXXXX")"
    if [ "$label" = "pty: login shell" ]; then
      printf 'echo pty-ok; id; exit\n' | timeout "$t" ssh "${opts[@]}" -tt vagrant@127.0.0.1 "$@" > "$log" 2>&1
    else
      timeout "$t" ssh "${opts[@]}" vagrant@127.0.0.1 "$@" > "$log" 2>&1 < /dev/null
    fi
    rc=$?
    { printf '== %s (rc=%s)\n' "$label" "$rc"; tail -n 60 "$log"; } >> "$out"
    rm -f "$log"
  }
  variant "exec: true" true
  variant "exec: /usr/bin/true" /usr/bin/true
  variant "exec: sh -c" sh -c 'echo sh-ok'
  variant "pty: login shell"
  say "live ssh variants: 4 sessions with ssh -vvv, in live-ssh.txt ($(grep -c '^== ' "$out") sections)"
}

# spec: tests/guest_logs.bats -- the QMP hunt (packer-plugin-macosx, branch ssh-window): the hunt template opens
#       a QMP socket beside its output directory; the QEMU is asked over it, twice 30 s apart, while it
#       still runs. The reader is the plugin branch's own bin/gate-build-evidence.sh (hunt/bin), which
#       only asks.
# spec: tests/guest_logs.bats -- the host's view of the live QEMU, twice 5 s apart: each thread's name, state and
#       kernel wait channel, and the process's I/O counters; a request stuck in the host shows as a thread in D
qemu_host_state() {  # $1 = the QEMU's pid; writes $dest/qemu-host.txt
  local pid="$1" out="$dest/qemu-host.txt" n t
  : > "$out"
  for n in 1 2; do
    {
      printf 'sample %s, host uptime %s s\n' "$n" "$(cut -d' ' -f1 /proc/uptime)"
      printf 'threads (name, state, wchan):\n'
      for t in /proc/"$pid"/task/*; do
        printf '%s %s %s\n' "$(cat "$t/comm" 2>/dev/null)" "$(sed -n 's/^State:\t//p' "$t/status" 2>/dev/null)" "$(cat "$t/wchan" 2>/dev/null)"
      done
      printf 'io:\n'; cat "/proc/$pid/io" 2>&1
    } >> "$out" 2>&1
    [ "$n" = 2 ] || sleep "${GUEST_LOGS_HOST_GAP:-5}"
  done
  say "qemu host state: two samples of its threads and I/O in qemu-host.txt"
}

qmp_read() {
  local sock reader="${GUEST_LOGS_QMP_READER:-$(dirname "$0")/../hunt/bin/gate-build-evidence.sh}" f
  sock=""
  for f in "$tpl"/output-*-qmp.sock; do [ -e "$f" ] && { sock="$f"; break; }; done
  if [ -z "$sock" ]; then say "qmp: no QMP socket (output-*-qmp.sock) in $tpl"; return 0; fi
  if timeout -k 10 "${GUEST_LOGS_QMP_TIMEOUT:-240}" bash "$reader" qmp "$sock" "$dest/qmp" 30 > "$dest/qmp-reader.txt" 2>&1; then
    if grep -q warning "$dest/qmp-reader.txt"; then say "qmp: the reader warned; what it said is in qmp-reader.txt"; return 0; fi
    say "qmp: read the QEMU over $sock twice, 30 s apart, into qmp/ ($(find "$dest/qmp" -type f 2>/dev/null | wc -l) files)"
  else
    say "qmp: the reader failed (exit $?); what it said is in qmp-reader.txt"
  fi
}

# spec: tests/guest_logs.bats -- packer -on-error=abort leaves its QEMU running on the disk; only
#       the pid packer logged, and only when that pid is a QEMU, is stopped
pid="$(sed -n 's/.*Started Qemu\. Pid: \([0-9][0-9]*\).*/\1/p' "$work/packer-debug.log" 2>/dev/null | tail -n 1)"
if [ -n "$pid" ]; then
  if [[ "$(cat "/proc/$pid/comm" 2>/dev/null)" == qemu-system-* ]]; then
    qemu_host_state "$pid"
    qmp_read
    live_guest "$pid"
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
