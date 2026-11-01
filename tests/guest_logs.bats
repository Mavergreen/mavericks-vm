#!/usr/bin/env bats
#
# A failed guest build keeps what a person needs to see what the guest did: packer's output and
# its timestamped debug log, the guest's serial console, and the guest's own logs, read offline
# from its disk. Never the disk, the box or any other part of Apple's OS.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export PATH="$REPO/tests/stubs:$PATH" STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
    : > "$STUB_LOG"
    export GUEST_LOGS_HOST_GAP=0
    TPL="$BATS_TEST_TMPDIR/work/templates/mavericks" WORK="$BATS_TEST_TMPDIR/work" DEST="$BATS_TEST_TMPDIR/logs"
    mkdir -p "$TPL/output-mavericks"
    printf 'packer line\nBuild errored: Error uploading script: Process exited with status 1\n' > "$WORK/packer-build.log"
    printf '2026/10/31 23:32:13 [DEBUG] scp stderr (length 5): oops\n' > "$WORK/packer-debug.log"
    printf 'hook: serial line\n' > "$TPL/output-mavericks-install.log"
    printf 'QFI\xfbdisk' > "$TPL/output-mavericks/mavericks.qcow2"
}

teardown() {
    for p in ${KILL_AFTER:-}; do kill "$p" 2>/dev/null || true; done
}

keep() { bash "$REPO/scripts/guest-logs.sh" "$TPL" "$WORK" "$DEST"; }

@test "packer's output, its debug log and the serial console are kept, and nothing of the disk" {
    run keep
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    cmp "$WORK/packer-build.log" "$DEST/packer-build.log"
    cmp "$WORK/packer-debug.log" "$DEST/packer-debug.log"
    cmp "$TPL/output-mavericks-install.log" "$DEST/serial-output-mavericks-install.log"
    run find "$DEST" -name '*.qcow2' -o -name '*.img' -o -name '*.box' -o -name '*.fd'
    [ -z "$output" ] || { echo "kept: $output"; false; }
    run grep -rlF 'QFI' "$DEST"
    [ -z "$output" ] || { echo "the disk's bytes reached: $output"; false; }
}

# spec: the offline read is diagnosis: whatever it cannot do, it says, and the build's own
#       failure stays the step's verdict
@test "a disk that cannot be attached is named in the summary, and the rest is still kept" {
    run keep
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ -f "$DEST/packer-debug.log" ]
    grep -q 'offline read: .*failed' "$DEST/summary.txt" || { cat "$DEST/summary.txt"; false; }
    grep -qF "$TPL/output-mavericks/mavericks.qcow2" "$DEST/summary.txt"
}

@test "with no disk left, the summary says so" {
    rm -rf "$TPL/output-mavericks"
    run keep
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    grep -q 'offline read: no guest disk' "$DEST/summary.txt" || { cat "$DEST/summary.txt"; false; }
}

# spec: packer -on-error=abort leaves the build's QEMU running, so its disk is still written to;
#       it is stopped first, and only that QEMU: the pid packer logged, when that pid is a QEMU
@test "the QEMU packer started is stopped before the disk is read" {
    q="$BATS_TEST_TMPDIR/bin/qemu-system-x86_64"; mkdir -p "${q%/*}"
    printf '#!/bin/bash\nwhile :; do sleep 0.2; done\n' > "$q"; chmod +x "$q"
    "$q" & pid=$!; KILL_AFTER="$pid"
    printf '2026/10/31 23:10:46 packer-plugin-qemu plugin: Started Qemu. Pid: %s\n' "$pid" >> "$WORK/packer-debug.log"
    run keep
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
    run kill -0 "$pid"
    [ "$status" -ne 0 ] || { echo "QEMU $pid still runs"; false; }
    grep -q "stopped the build's QEMU (pid $pid)" "$DEST/summary.txt" || { cat "$DEST/summary.txt"; false; }
}

# spec: Actions run 41312175505 (build 8): the guest sat at its installer's last line for 45 minutes and
#       the log could not say whether it was spinning or halted; a QEMU burning its vCPUs and one
#       idle are different hangs, so the summary gives the QEMU's CPU time against its age, and its state
@test "the summary says how much CPU the build's QEMU used, and its state, before it is stopped" {
    q="$BATS_TEST_TMPDIR/bin/qemu-system-x86_64"; mkdir -p "${q%/*}"
    printf '#!/bin/bash\nend=$((SECONDS + 1)); while [ $SECONDS -le $end ]; do :; done\nwhile :; do sleep 0.2; done\n' > "$q"; chmod +x "$q"
    "$q" & pid=$!; KILL_AFTER="$pid"
    sleep 2.5
    printf 'packer-plugin-qemu plugin: Started Qemu. Pid: %s\n' "$pid" >> "$WORK/packer-debug.log"
    run keep
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    line="$(grep "^qemu (pid $pid)" "$DEST/summary.txt")" || { cat "$DEST/summary.txt"; false; }
    [[ "$line" =~ ": state "[SR]", "([0-9.]+)" s of CPU in "([0-9]+)" s (" ]] || { echo "$line"; false; }
    awk -v c="${BASH_REMATCH[1]}" 'BEGIN { exit !(c >= 0.5) }' || { echo "$line"; false; }
    n=$(grep -n "^qemu (pid $pid)" "$DEST/summary.txt" | cut -d: -f1); k=$(grep -n "^stopped the build's QEMU" "$DEST/summary.txt" | cut -d: -f1)
    [ "$n" -lt "$k" ] || { cat "$DEST/summary.txt"; false; }
}

# spec: Actions run 41318225783 (build 15) -- the live guest is asked, as the template's own user with
#       its own first-boot-only key (a copy at mode 0600), on the port packer logged, once and bounded
@test "the live guest is asked read-only questions over ssh, on packer's port, with a private copy of the template's key" {
    printf 'KEY\n' > "$TPL/vagrant-standard-insecure-first-boot-only.key.rsa"; chmod 0644 "$TPL/vagrant-standard-insecure-first-boot-only.key.rsa"
    printf '2026/11/01 15:00:25 plugin: [INFO] Attempting SSH connection to 127.0.0.1:2797...\n' >> "$WORK/packer-debug.log"
    q="$BATS_TEST_TMPDIR/bin/qemu-system-x86_64"; mkdir -p "${q%/*}"
    printf '#!/bin/bash\nwhile :; do sleep 0.2; done\n' > "$q"; chmod +x "$q"
    "$q" & pid=$!; KILL_AFTER="$pid"
    printf 'plugin: Started Qemu. Pid: %s\n' "$pid" >> "$WORK/packer-debug.log"
    # an ssh in front of the stub's, which says what mode the key it was given has
    cat > "$BATS_TEST_TMPDIR/bin/ssh" <<'WRAP'
#!/bin/bash
k=""; prev=""; for a in "$@"; do [ "$prev" = -i ] && k="$a"; prev="$a"; done
printf 'key-mode %s\n' "$(stat -c %a "$k")" >> "$STUB_LOG"
exec "$(dirname "$0")/../../../../../stubs/ssh" "$@"
WRAP
    sed -i "s|exec \"\$(dirname \"\$0\")/../../../../../stubs/ssh\"|exec \"$REPO/tests/stubs/ssh\"|" "$BATS_TEST_TMPDIR/bin/ssh"; chmod +x "$BATS_TEST_TMPDIR/bin/ssh"
    PATH="$BATS_TEST_TMPDIR/bin:$PATH" STUB_SSH_UP=1 run keep
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    grep -qxF 'key-mode 600' "$STUB_LOG" || { cat "$STUB_LOG"; false; }
    l="$(grep '^ssh ' "$STUB_LOG")"
    [[ "$l" == *"-p 2797 vagrant@127.0.0.1 sh -s"* ]] || { echo "$l"; false; }
    [[ "$l" == *"BatchMode=yes"* && "$l" == *"-i $WORK/live-key"* ]] || { echo "$l"; false; }
    [ ! -e "$WORK/live-key" ]
    grep -q '^== scp -vt /tmp' "$DEST/live-guest.txt" || { cat "$DEST/live-guest.txt"; false; }
    grep -q 'live guest: asked it over ssh on port 2797 (exit 0)' "$DEST/summary.txt" || { cat "$DEST/summary.txt"; false; }
    n=$(grep -n 'live guest' "$DEST/summary.txt" | cut -d: -f1); k=$(grep -n "^stopped the build's QEMU" "$DEST/summary.txt" | cut -d: -f1)
    [ "$n" -lt "$k" ]
}

# spec: the QMP hunt (packer-plugin-macosx, branch ssh-window) -- the build's QEMU is asked, over the QMP
#       socket the hunt template opens beside its output directory, what it thinks, twice 30 s apart,
#       while it still runs: before the live guest is asked and before it is stopped
qemu_up() {
    q="$BATS_TEST_TMPDIR/bin/qemu-system-x86_64"; mkdir -p "${q%/*}"
    printf '#!/bin/bash\nwhile :; do sleep 0.2; done\n' > "$q"; chmod +x "$q"
    "$q" & pid=$!; KILL_AFTER="$pid"
    printf 'plugin: Started Qemu. Pid: %s\n' "$pid" >> "$WORK/packer-debug.log"
}
qmp_reader() {  # a stand-in reader: records its arguments, leaves a file where it was told
    cat > "$BATS_TEST_TMPDIR/reader" <<'RD'
#!/bin/bash
printf 'reader %s\n' "$*" >> "$STUB_LOG"
if [ -n "${READER_FAIL:-}" ]; then echo "reader: warning: no" >&2; exit 1; fi
if [ -n "${READER_WARN:-}" ]; then echo "gate-build-evidence: warning: qmp: could not read the QEMU" >&2; exit 0; fi
mkdir -p "$3" && echo "== query-status ==" > "$3/read-1.txt"
RD
    chmod +x "$BATS_TEST_TMPDIR/reader"
    export GUEST_LOGS_QMP_READER="$BATS_TEST_TMPDIR/reader"
}

# spec: Actions run 41353051295 (build 30): the QEMU's vCPUs sat in HLT and its block counters did not move
#       for an hour; whether a host-side request was stuck needs the host's view of its threads and I/O
@test "hunt: the host's view of the live QEMU (its threads' states and wait channels, its I/O) is kept before it is stopped" {
    qemu_up
    run keep
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    grep -q '^threads (name, state, wchan):' "$DEST/qemu-host.txt" || { cat "$DEST/qemu-host.txt"; false; }
    grep -q '^qemu-system-x86' "$DEST/qemu-host.txt" || { cat "$DEST/qemu-host.txt"; false; }
    grep -q '^io:' "$DEST/qemu-host.txt"
    grep -q 'rchar' "$DEST/qemu-host.txt"
    grep -q '^qemu host state: ' "$DEST/summary.txt" || { cat "$DEST/summary.txt"; false; }
    n=$(grep -n '^qemu host state' "$DEST/summary.txt" | cut -d: -f1); k=$(grep -n "^stopped the build's QEMU" "$DEST/summary.txt" | cut -d: -f1)
    [ "$n" -lt "$k" ]
}

@test "hunt: the host's two samples are apart, so what moves in the QEMU's I/O between them shows" {
    qemu_up
    GUEST_LOGS_HOST_GAP=2 run keep
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    a=$(sed -n 's/^sample 1, host uptime \([0-9.]*\) s$/\1/p' "$DEST/qemu-host.txt"); b=$(sed -n 's/^sample 2, host uptime \([0-9.]*\) s$/\1/p' "$DEST/qemu-host.txt")
    awk -v a="$a" -v b="$b" 'BEGIN { exit !(a != "" && b - a >= 2) }' || { cat "$DEST/qemu-host.txt"; false; }
}

@test "hunt: a live QEMU with a QMP socket is read twice, 30 s apart, into qmp/, before it is stopped" {
    qemu_up; qmp_reader
    : > "$TPL/output-mavericks-qmp.sock"
    run keep
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    grep -qxF "reader qmp $TPL/output-mavericks-qmp.sock $DEST/qmp 30" "$STUB_LOG" || { cat "$STUB_LOG"; false; }
    [ -f "$DEST/qmp/read-1.txt" ]
    grep -q '^qmp: read the QEMU' "$DEST/summary.txt" || { cat "$DEST/summary.txt"; false; }
    n=$(grep -n '^qmp: ' "$DEST/summary.txt" | cut -d: -f1); k=$(grep -n "^stopped the build's QEMU" "$DEST/summary.txt" | cut -d: -f1)
    [ "$n" -lt "$k" ]
}

@test "hunt: the QMP read comes before the live guest is asked" {
    qemu_up; qmp_reader
    : > "$TPL/output-mavericks-qmp.sock"
    printf 'KEY\n' > "$TPL/vagrant-standard-insecure-first-boot-only.key.rsa"
    printf 'plugin: [INFO] Attempting SSH connection to 127.0.0.1:2797...\n' >> "$WORK/packer-debug.log"
    run keep
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    q=$(grep -n '^reader ' "$STUB_LOG" | cut -d: -f1); l=$(grep -n '^ssh ' "$STUB_LOG" | head -n 1 | cut -d: -f1)
    [ "$q" -lt "$l" ] || { cat "$STUB_LOG"; false; }
}

@test "hunt: a reader that fails costs the QMP evidence only, and the summary says so" {
    qemu_up; qmp_reader
    : > "$TPL/output-mavericks-qmp.sock"
    READER_FAIL=1 run keep
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    grep -q '^qmp: the reader failed' "$DEST/summary.txt" || { cat "$DEST/summary.txt"; false; }
    grep -q "stopped the build's QEMU (pid $pid)" "$DEST/summary.txt"
    cmp "$WORK/packer-build.log" "$DEST/packer-build.log"
}

@test "hunt: a reader that exits 0 but warned (the usual way it fails) is not reported as a read" {
    qemu_up; qmp_reader
    : > "$TPL/output-mavericks-qmp.sock"
    READER_WARN=1 run keep
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    grep -q '^qmp: the reader warned' "$DEST/summary.txt" || { cat "$DEST/summary.txt"; false; }
    grep -q 'could not read the QEMU' "$DEST/qmp-reader.txt"
}

@test "hunt: a reader that hangs is given up on, and the rest is still kept" {
    qemu_up
    cat > "$BATS_TEST_TMPDIR/reader" <<'RD'
#!/bin/bash
sleep 30
RD
    chmod +x "$BATS_TEST_TMPDIR/reader"; export GUEST_LOGS_QMP_READER="$BATS_TEST_TMPDIR/reader"
    : > "$TPL/output-mavericks-qmp.sock"
    s=$SECONDS
    GUEST_LOGS_QMP_TIMEOUT=1 run keep
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ $((SECONDS - s)) -lt 15 ] || { echo "took $((SECONDS - s)) s"; false; }
    grep -q '^qmp: the reader failed' "$DEST/summary.txt" || { cat "$DEST/summary.txt"; false; }
    grep -q "stopped the build's QEMU" "$DEST/summary.txt"
}

@test "hunt: no QMP socket is said so in the summary, and nothing is read" {
    qemu_up; qmp_reader
    run keep
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    grep -q '^qmp: no QMP socket' "$DEST/summary.txt" || { cat "$DEST/summary.txt"; false; }
    run grep -q '^reader ' "$STUB_LOG"
    [ "$status" -ne 0 ]
}

@test "hunt: with no QEMU left to ask, the QMP socket is not read" {
    qmp_reader
    : > "$TPL/output-mavericks-qmp.sock"
    run keep
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    run grep -q '^reader ' "$STUB_LOG"
    [ "$status" -ne 0 ]
}

# spec: Actions run 41353051295 (builds 7 and 38): the live guest's `sh -s` exited 1 with no output, as packer's
#       scp had 151 times: the session starts and its command dies. Which part of an sshd session fails is
#       told apart by a few more bounded sessions, each with ssh's own -vvv: an exec of `true`, of
#       /usr/bin/true by path, of `sh -c`, and a pty session (the login shell), into live-ssh.txt
@test "hunt: the live guest is also asked with plain commands, by path, and with a pty, each with ssh's own -vvv" {
    printf 'KEY\n' > "$TPL/vagrant-standard-insecure-first-boot-only.key.rsa"
    printf 'plugin: [INFO] Attempting SSH connection to 127.0.0.1:2797...\n' >> "$WORK/packer-debug.log"
    qemu_up
    STUB_SSH_UP=1 run keep
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    for v in "true" "/usr/bin/true" "sh -c" "-tt"; do
        grep -q "^ssh .*-vvv.* -p 2797 .*$v" "$STUB_LOG" || { echo "no ssh -vvv for: $v"; cat "$STUB_LOG"; false; }
    done
    grep -q '^== exec: true (rc=0)' "$DEST/live-ssh.txt" || { cat "$DEST/live-ssh.txt"; false; }
    grep -q '^== exec: /usr/bin/true (rc=0)' "$DEST/live-ssh.txt"
    grep -q '^== exec: sh -c (rc=0)' "$DEST/live-ssh.txt"
    grep -q '^== pty: login shell (rc=0)' "$DEST/live-ssh.txt"
    grep -q 'live ssh variants' "$DEST/summary.txt" || { cat "$DEST/summary.txt"; false; }
    [ ! -e "$WORK/live-key" ]
}

@test "hunt: a variant that hangs is given up on, the others still run" {
    printf 'KEY\n' > "$TPL/vagrant-standard-insecure-first-boot-only.key.rsa"
    printf 'plugin: [INFO] Attempting SSH connection to 127.0.0.1:2797...\n' >> "$WORK/packer-debug.log"
    qemu_up
    s=$SECONDS
    GUEST_LOGS_LIVE_TIMEOUT=2 STUB_SSH_HANG=20 run keep
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ $((SECONDS - s)) -lt 40 ] || { echo "took $((SECONDS - s)) s"; false; }
    [ "$(grep -c '^== ' "$DEST/live-ssh.txt")" -eq 4 ] || { cat "$DEST/live-ssh.txt"; false; }
}

@test "a guest that answers nothing is said so, with ssh's exit, and nothing else is lost" {
    printf 'KEY\n' > "$TPL/vagrant-standard-insecure-first-boot-only.key.rsa"
    printf 'plugin: [INFO] Attempting SSH connection to 127.0.0.1:2797...\n' >> "$WORK/packer-debug.log"
    q="$BATS_TEST_TMPDIR/bin/qemu-system-x86_64"; mkdir -p "${q%/*}"
    printf '#!/bin/bash\nwhile :; do sleep 0.2; done\n' > "$q"; chmod +x "$q"
    "$q" & pid=$!; KILL_AFTER="$pid"
    printf 'plugin: Started Qemu. Pid: %s\n' "$pid" >> "$WORK/packer-debug.log"
    run keep
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    grep -q 'live guest: asked it over ssh on port 2797 (exit 255)' "$DEST/summary.txt" || { cat "$DEST/summary.txt"; false; }
    cmp "$WORK/packer-build.log" "$DEST/packer-build.log"
}

@test "a guest whose ssh hangs is given up on, and the rest is still kept" {
    printf 'KEY\n' > "$TPL/vagrant-standard-insecure-first-boot-only.key.rsa"
    printf 'plugin: [INFO] Attempting SSH connection to 127.0.0.1:2797...\n' >> "$WORK/packer-debug.log"
    q="$BATS_TEST_TMPDIR/bin/qemu-system-x86_64"; mkdir -p "${q%/*}"
    printf '#!/bin/bash\nwhile :; do sleep 0.2; done\n' > "$q"; chmod +x "$q"
    "$q" & pid=$!; KILL_AFTER="$pid"
    printf 'plugin: Started Qemu. Pid: %s\n' "$pid" >> "$WORK/packer-debug.log"
    s=$SECONDS
    GUEST_LOGS_LIVE_TIMEOUT=1 STUB_SSH_HANG=20 run keep
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ $((SECONDS - s)) -lt 15 ] || { echo "took $((SECONDS - s)) s"; false; }
    grep -q 'live guest: asked it over ssh on port 2797 (exit 124)' "$DEST/summary.txt" || { cat "$DEST/summary.txt"; false; }
}

@test "no port or no key: the live guest is not asked, and the summary says why" {
    run keep
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    run grep -q '^ssh ' "$STUB_LOG"
    [ "$status" -ne 0 ] || { cat "$STUB_LOG"; false; }
}

@test "a logged pid that is not a QEMU is left alone" {
    sleep 300 & pid=$!; KILL_AFTER="$pid"
    printf 'packer-plugin-qemu plugin: Started Qemu. Pid: %s\n' "$pid" >> "$WORK/packer-debug.log"
    run keep
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    kill -0 "$pid"
    grep -q "pid $pid is not a QEMU" "$DEST/summary.txt" || { cat "$DEST/summary.txt"; false; }
}

# spec: what leaves the guest is its logs, by path, and nothing else; each at most 16 MiB (its end)
@test "from the guest's volume: its logs, crash reports and first-boot state, and nothing else" {
    T="$BATS_TEST_TMPDIR/vol"
    mkdir -p "$T/private/var/log/asl" "$T/private/var/db/.guest-macosx-firstboot" \
        "$T/Library/Logs/DiagnosticReports" "$T/Users/vagrant/Library/Logs/DiagnosticReports" \
        "$T/System/Library/Kernels" "$T/Users/vagrant/Documents"
    echo sys > "$T/private/var/log/system.log"
    echo inst > "$T/private/var/log/install.log"
    echo fb > "$T/private/var/log/guest-macosx-firstboot.log"
    echo crash > "$T/private/var/log/launchd-pid1.crash"
    echo bin > "$T/private/var/log/asl/2026.10.31.U0.asl"
    echo bin > "$T/private/var/log/wtmp"
    echo done > "$T/private/var/db/.guest-macosx-firstboot/.done"
    echo top > "$T/.guest-macosx-firstboot.log"
    echo stall > "$T/Library/Logs/DiagnosticReports/x_2026-10-31.shutdownStall"
    echo panic > "$T/Library/Logs/DiagnosticReports/Kernel_2026-10-31.panic"
    echo app > "$T/Users/vagrant/Library/Logs/DiagnosticReports/sshd_2026.crash"
    echo kernel > "$T/System/Library/Kernels/kernel"
    echo mine > "$T/Users/vagrant/Documents/notes.log"
    head -c $((17 * 1024 * 1024)) /dev/zero | tr '\0' x > "$T/private/var/log/big.log"
    echo END >> "$T/private/var/log/big.log"
    run bash "$REPO/scripts/guest-logs.sh" copy "$T" "$DEST/guest"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    for f in private_var_log_system.log private_var_log_install.log private_var_log_guest-macosx-firstboot.log \
        private_var_log_launchd-pid1.crash private_var_db_.guest-macosx-firstboot_.done .guest-macosx-firstboot.log \
        Library_Logs_DiagnosticReports_x_2026-10-31.shutdownStall Library_Logs_DiagnosticReports_Kernel_2026-10-31.panic \
        Users_vagrant_Library_Logs_DiagnosticReports_sshd_2026.crash; do
        [ -f "$DEST/guest/$f" ] || { ls -A "$DEST/guest"; echo "missing $f"; false; }
    done
    [ "$(cat "$DEST/guest/private_var_log_system.log")" = sys ]
    run ls -A "$DEST/guest"
    [ "${#lines[@]}" -eq 10 ] || { echo "$output"; false; }
    [ "$(wc -c < "$DEST/guest/private_var_log_big.log")" -eq $((16 * 1024 * 1024)) ]
    [ "$(tail -c 4 "$DEST/guest/private_var_log_big.log")" = END ]
}
