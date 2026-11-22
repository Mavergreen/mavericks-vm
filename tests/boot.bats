#!/usr/bin/env bats
#
# Booting the cached guest the way the box's own Vagrantfile does, from a
# throwaway overlay, and refusing a runner without room before starting.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export PATH="$REPO/tests/stubs:$PATH" STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
    export STUB_QEMU_ARGV="$BATS_TEST_TMPDIR/qemu.argv" HOME="$BATS_TEST_TMPDIR/home"
    export RUNNER_TEMP="$BATS_TEST_TMPDIR/runner-temp"; mkdir -p "$RUNNER_TEMP"
    mkdir -p "$HOME"; : > "$STUB_LOG"
    export MVM_DATA_DIR="$BATS_TEST_TMPDIR/data" MVM_MEM=4096 MVM_CPU=2 \
        MVM_CPU_MODEL='Penryn,+ssse3,+sse4.1,+sse4.2' MVM_NAT='tcp:8080:80 udp:8081:80' \
        MVM_KVM=/dev/null MVM_SSH_TIMEOUT=2 MVM_SSH_INTERVAL=1
    BOX="$BATS_TEST_TMPDIR/layer"; mkdir -p "$BOX"
    for f in box_0.img OVMF_CODE.fd OVMF_VARS.fd opencore.img; do : > "$BOX/$f"; done
}

boot() { bash "$REPO/scripts/boot.sh" "$@"; }
argv_has() { grep -qxF -- "$1" "$STUB_QEMU_ARGV"; }
uuid_of() { awk 'p { print; exit } $0 == "-uuid" { p = 1 }' "$STUB_QEMU_ARGV"; }
# spec: packer-plugin-macosx docs/decisions/0024 -- the address rule, written out again here so a
#       change to boot.sh's cannot pass by matching itself: 52:54:00, then three bytes of the UUID's
#       SHA-256, six hex digits further on past each leading 1234
mac_of() {
    local h i=0
    h=$(printf '%s' "$1" | sha256sum | cut -c1-64)
    while [ "${h:$i:4}" = 1234 ]; do i=$((i + 6)); done
    printf '52:54:00:%s:%s:%s\n' "${h:$i:2}" "${h:$((i + 2)):2}" "${h:$((i + 4)):2}"
}

@test "QEMU gets the box's machine, CPU, memory, cores and devices" {
    STUB_SSH_UP=1 run boot "$BOX"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    argv_has q35,vmport=off,accel=kvm
    argv_has 'Penryn,+ssse3,+sse4.1,+sse4.2'
    argv_has 4096M
    argv_has 2
    argv_has "if=pflash,format=raw,unit=0,readonly=on,file=$BOX/OVMF_CODE.fd"
    argv_has "id=opencore,if=none,format=raw,snapshot=on,file=$BOX/opencore.img"
    argv_has 'virtio-blk-pci,drive=opencore,bootindex=0,bus=pcie.0,addr=0x10'
    argv_has 'ich9-usb-ehci1,id=ehci,bus=pcie.0,addr=0x1d.0'
    argv_has 'usb-kbd,bus=ehci.0'
    argv_has 'usb-tablet,bus=ehci.0'
    # spec: packer-plugin-macosx docs/decisions/0035 -- USB carries input alone: no companion,
    #       no XHCI, no usb-storage, no mouse, no q35 USB
    run grep -qE 'uhci|xhci|ohci|usb-storage|usb-mouse|masterbus|usb=on|ide.2' "$STUB_QEMU_ARGV"
    [ "$status" -eq 1 ]
    run grep -qxE -- '-usb|-usbdevice' "$STUB_QEMU_ARGV"
    [ "$status" -eq 1 ]
    argv_has 'ide-hd,bus=ide.0,drive=target'
    argv_has "e1000-82545em,netdev=net0,mac=$(mac_of "$(uuid_of)")"
}

@test "the box's devices are the one shape, exactly: no second input device, no stray virtio or disk" {
    STUB_SSH_UP=1 run boot "$BOX"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    # spec: packer-plugin-macosx docs/decisions/0035 -- every -device and -drive value, in order,
    #       and no flag that makes a device of its own
    got=$(awk 'p { print; p = 0 } $0 == "-device" || $0 == "-drive" { p = 1 }' "$STUB_QEMU_ARGV")
    want="if=pflash,format=raw,unit=0,readonly=on,file=$BOX/OVMF_CODE.fd
if=pflash,format=raw,unit=1,snapshot=on,file=$BOX/OVMF_VARS.fd
id=target,if=none,format=qcow2,detect-zeroes=unmap,discard=unmap,file=$MVM_DATA_DIR/overlay.qcow2
ide-hd,bus=ide.0,drive=target
id=opencore,if=none,format=raw,snapshot=on,file=$BOX/opencore.img
virtio-blk-pci,drive=opencore,bootindex=0,bus=pcie.0,addr=0x10
e1000-82545em,netdev=net0,mac=$(mac_of "$(uuid_of)")
ich9-usb-ehci1,id=ehci,bus=pcie.0,addr=0x1d.0
usb-kbd,bus=ehci.0
usb-tablet,bus=ehci.0
VGA,vgamem_mb=64"
    [ "$got" = "$want" ] || { diff <(echo "$want") <(echo "$got"); false; }
    run grep -qxE -- '-usb|-usbdevice|-hd[a-d]|-cdrom|-fd[ab]|-sd|-mtdblock|-M|-machine=.*' "$STUB_QEMU_ARGV"
    [ "$status" -eq 1 ]
    [ "$(grep -cxF -- -machine "$STUB_QEMU_ARGV")" -eq 1 ]
}

@test "the cached disk is a read-only backing file; writes go to an overlay under data-dir" {
    STUB_SSH_UP=1 run boot "$BOX"
    [ "$status" -eq 0 ]
    grep -q "^qemu-img create -f qcow2 -F qcow2 -b $BOX/box_0.img $MVM_DATA_DIR/" "$STUB_LOG"
    # spec: zeros a guest writes (diskutil secureErase, a test's dd) become holes, not stored
    #       blocks: a zero-fill grew an overlay by 51.7 GB without it and by 344 MB with it
    #       (packer-plugin-macosx TestTheTargetDriveStoresZerosAsHoles, measured 2026-10-07)
    grep -q "^id=target,if=none,format=qcow2,detect-zeroes=unmap,discard=unmap,file=$MVM_DATA_DIR/" "$STUB_QEMU_ARGV"
}

# spec: a layer or prepared image is a delta over the image below it; booting one whose chain has a
#       missing link fails late and obscurely inside the guest, so the chain is checked first
@test "the backing chain is checked before the overlay is made" {
    STUB_SSH_UP=1 run boot "$BOX"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    ci=$(grep -nxF "qemu-img info --backing-chain $BOX/box_0.img" "$STUB_LOG" | cut -d: -f1)
    cc=$(grep -n '^qemu-img create' "$STUB_LOG" | cut -d: -f1)
    [ -n "$ci" ] && [ -n "$cc" ] && [ "$ci" -lt "$cc" ] || { cat "$STUB_LOG"; false; }
}

@test "a broken backing chain fails, by name and with qemu-img's words, before QEMU starts" {
    STUB_QEMU_IMG_INFO_FAIL="qemu-img: Could not open '../box/box_0.img': No such file or directory" \
        STUB_SSH_UP=1 run boot "$BOX"
    [ "$status" -eq 1 ]
    [[ "$output" == *"::error title=mavericks-vm::booting the layer image: the cached guest's backing chain is broken: qemu-img: Could not open '../box/box_0.img': No such file or directory"* ]] || false
    [ ! -e "$STUB_QEMU_ARGV" ]
    run grep -q '^qemu-img create' "$STUB_LOG"
    [ "$status" -ne 0 ]
}

# spec: a workflow command is one line, so qemu-img's lines are joined as GitHub's annotations
#       want them: % as %25, CR as %0D, LF as %0A (task 3 review, minor 3)
@test "a broken chain's multi-line error is one annotation, its newlines encoded" {
    STUB_QEMU_IMG_INFO_FAIL=$'qemu-img: first line\n50% of the second' run boot "$BOX"
    [ "$status" -eq 1 ]
    [[ "$output" == *"backing chain is broken: qemu-img: first line%0A50%25 of the second"* ]] || false
    [ "$(grep -c '::error' <<< "$output")" -eq 1 ] || { echo "$output"; false; }
    [[ "$output" != *$'\n50% of the second'* ]] || false
}

# spec: one ::error per failure, naming the image and the step; boot.sh names its own, so main.sh
#       does not, and a failure boot.sh did not foresee is still named once
@test "a failure boot.sh does not foresee is named once, with the image" {
    fake="$BATS_TEST_TMPDIR/fake"; mkdir -p "$fake"
    printf '#!/bin/bash\nexit 1\n' > "$fake/qemu-system-x86_64"; chmod +x "$fake/qemu-system-x86_64"
    PATH="$fake:$PATH" STUB_SSH_UP=1 run boot "$BOX"
    [ "$status" -ne 0 ]
    [ "$(grep -c '::error' <<< "$output")" -eq 1 ] || { echo "$output"; false; }
    [[ "$output" == *"::error title=mavericks-vm::booting the layer image failed"* ]] || false
}

@test "the prepared image's boot is named for the prepared image" {
    P="$BATS_TEST_TMPDIR/prepared"; mkdir -p "$P"
    for f in box_0.img OVMF_CODE.fd OVMF_VARS.fd; do : > "$P/$f"; done
    run boot "$P"
    [ "$status" -eq 1 ]
    [[ "$output" == *"::error title=mavericks-vm::booting the prepared image: the cached guest has no opencore.img"* ]] || false
}

@test "cpu-model reaches -cpu unchanged" {
    MVM_CPU_MODEL=Nehalem STUB_SSH_UP=1 run boot "$BOX"
    [ "$status" -eq 0 ]
    argv_has Nehalem
}

@test "nat lines become hostfwd rules beside the SSH forward" {
    STUB_SSH_UP=1 run boot "$BOX"
    grep -q 'hostfwd=tcp::8080-:80' "$STUB_QEMU_ARGV"
    grep -q 'hostfwd=udp::8081-:80' "$STUB_QEMU_ARGV"
    grep -q 'hostfwd=tcp:127.0.0.1:[0-9]*-:22' "$STUB_QEMU_ARGV"
}

@test "after boot, ssh mavericks reaches the guest" {
    STUB_SSH_UP=1 run boot "$BOX"
    [ "$status" -eq 0 ]
    grep -q '^Host mavericks$' "$HOME/.ssh/config"
    grep -q 'User vagrant' "$HOME/.ssh/config"
    grep -q "IdentityFile $MVM_DATA_DIR/" "$HOME/.ssh/config"
}

@test "the SSH wait names the config it wrote: ssh reads the passwd home, not \$HOME" {
    STUB_SSH_UP=1 run boot "$BOX"
    [ "$status" -eq 0 ]
    grep -qxF "ssh -F $HOME/.ssh/config mavericks true" "$STUB_LOG"
}

@test "no SSH within the timeout fails, with the serial log's tail" {
    mkdir -p "$MVM_DATA_DIR"; printf 'panic(cpu 0 caller ...)\n' > "$MVM_DATA_DIR/serial.log"
    run boot "$BOX"
    [ "$status" -ne 0 ]
    [[ "$output" == *"panic(cpu 0"* ]] || false
}

# spec: the timeout is wall-clock time: each attempt against an unanswering guest can itself take
#       ConnectTimeout, so counting only the sleeps between attempts tripled it on GitHub (Actions
#       run 37539764898: a 600 s timeout took 30 minutes)
@test "the SSH timeout counts the attempts' own time, not only the sleeps between them" {
    start=$SECONDS
    STUB_SSH_HANG=2 run boot "$BOX"
    [ "$status" -ne 0 ]
    [ $((SECONDS - start)) -le 5 ] || { echo "took $((SECONDS - start))s for a 2s timeout"; false; }
}

# spec: QEMU daemonizes and outlives the step, so whatever is in its environment any later step
#       can read from /proc/<pid>/environ: neither the image key nor the token may be there
#       (final review, I2)
@test "QEMU never inherits the image key or the registry token" {
    MVM_IMAGE_KEY='AGE-SECRET-KEY-1NEVERINQEMU' MVM_TOKEN='ghp_neverinqemu' STUB_SSH_UP=1 run boot "$BOX"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    run grep -E 'NEVERINQEMU|neverinqemu' "$STUB_QEMU_ARGV.env"
    [ "$status" -ne 0 ]
}

# spec: an ssh session to a guest that dies waits forever without keepalives; with them a dead
#       guest fails the step within about two minutes, named by ssh
@test "the ssh config notices a dead guest instead of waiting forever" {
    STUB_SSH_UP=1 run boot "$BOX"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    grep -qE '^ *ServerAliveInterval [0-9]+$' "$HOME/.ssh/config"
    grep -qE '^ *ServerAliveCountMax [0-9]+$' "$HOME/.ssh/config"
}

@test "a runner without /dev/kvm is refused, by name" {
    MVM_KVM=/nonexistent run boot "$BOX"
    [ "$status" -ne 0 ]
    [[ "$output" == *"::error title=mavericks-vm::booting the layer image: /nonexistent"* ]] || false
    [ "$(grep -c '::error' <<< "$output")" -eq 1 ] || { echo "$output"; false; }
}

@test "space: a data-dir with less room than needed is refused, naming both numbers" {
    mkdir -p "$MVM_DATA_DIR"
    MVM_SPACE_AVAILABLE_KIB=1048576 run bash "$REPO/scripts/space.sh" hit
    [ "$status" -ne 0 ]
    [[ "$output" == *"1 GiB"* ]] || false
    [[ "$output" == *"$MVM_DATA_DIR"* ]] || false
    MVM_SPACE_AVAILABLE_KIB=$((100*1024*1024)) run bash "$REPO/scripts/space.sh" miss
    [ "$status" -eq 0 ]
    # spec: cache-after-prepare's snapshot writes a whole new image and encrypts it, which no check
    #       covered (final review, I5)
    MVM_SPACE_AVAILABLE_KIB=1048576 run bash "$REPO/scripts/space.sh" prepare
    [ "$status" -ne 0 ]
    [[ "$output" == *"prepare"* ]] || false
}

# spec: one ::error per failure, naming the image and the step it was checked for (task 3 review,
#       minor 2); main.sh adds none of its own
@test "space: each check names the image and the step it makes room for" {
    mkdir -p "$MVM_DATA_DIR"
    while IFS='|' read -r what want; do
        MVM_SPACE_AVAILABLE_KIB=1048576 run bash "$REPO/scripts/space.sh" "$what"
        [ "$status" -eq 1 ]
        [[ "$output" == "::error title=mavericks-vm::$want: $MVM_DATA_DIR has 1 GiB free"* ]] || { echo "$what: $output"; false; }
    done <<'TABLE'
hit|pulling the cached images
miss|building the base image and the layer over it
layer|building the layer image
prepare|snapshotting the prepared image
TABLE
}

@test "a usage error names what boot.sh does" {
    run boot
    [ "$status" -eq 2 ]
    [[ "$output" == *"booting"* ]] || false
}

# spec: packer-plugin-macosx docs/decisions/0024 -- a guest whose firmware gives no UUID waits 30 s
#       at every cold boot for one (cfprefsd's gethostuuid), and distinct guests must never share
#       one: every launcher gives QEMU a -uuid of its own, and the NIC an address derived from it
@test "QEMU gets a -uuid of its own, and the NIC the address ADR 0024 derives from it" {
    STUB_SSH_UP=1 run boot "$BOX"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    u="$(uuid_of)"
    [[ "$u" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || { echo "-uuid '$u'"; false; }
    [ "$u" != 00000000-0000-0000-0000-000000000000 ]
    argv_has "e1000-82545em,netdev=net0,mac=$(mac_of "$u")"
    [[ "$output" == *"boot.sh: host UUID $u (new, kept in $RUNNER_TEMP/mavericks-vm-host-uuid); NIC $(mac_of "$u"), derived from it"* ]] \
        || { echo "$output"; false; }
}

# spec: the derived address, for two UUIDs, as packer-plugin-macosx's lib/common.sh derived_mac
#       gives it (2026-11-01): one plain, and one whose SHA-256 starts 1234, so never 52:54:00:12:34
@test "the address is the plugin's for the same UUID, and never in QEMU's own 52:54:00:12:34 range" {
    while read -r u want; do
        rm -rf "${RUNNER_TEMP:?}"/*; printf '%s\n' "$u" > "$RUNNER_TEMP/mavericks-vm-host-uuid"
        STUB_SSH_UP=1 run boot "$BOX"
        [ "$status" -eq 0 ] || { echo "$output"; false; }
        argv_has "e1000-82545em,netdev=net0,mac=$want" || { grep e1000 "$STUB_QEMU_ARGV"; echo "want $want"; false; }
    done <<'PAIRS'
0f8fad5b-d9cb-469f-a165-70867728950e 52:54:00:c8:12:e1
0003bb23-0000-4000-8000-00000003bb23 52:54:00:f4:2d:70
PAIRS
}

# spec: on a hosted runner the machine is the job: data-dir and the cached images outlive it on a
#       self-hosted runner, RUNNER_TEMP never does. So the UUID is made at the job's first boot,
#       kept in RUNNER_TEMP, and the same at every later boot of the job (prepare's guest, then
#       the prepared one); another job, at once or later, gets its own.
@test "a second boot in the same job is the same machine; another job is another machine" {
    STUB_SSH_UP=1 run boot "$BOX"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    first="$(uuid_of)"
    STUB_SSH_UP=1 run boot "$BOX"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$(uuid_of)" = "$first" ]
    [[ "$output" == *"host UUID $first (kept in $RUNNER_TEMP/mavericks-vm-host-uuid)"* ]] || { echo "$output"; false; }
    export RUNNER_TEMP="$BATS_TEST_TMPDIR/another-job"; mkdir -p "$RUNNER_TEMP"
    STUB_SSH_UP=1 run boot "$BOX"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$(uuid_of)" != "$first" ]
    run find "$MVM_DATA_DIR" -name '*uuid*'
    [ -z "$output" ] || { echo "kept in data-dir: $output"; false; }
}

@test "a kept UUID that is not one is replaced, and so said" {
    printf 'not-a-uuid\n' > "$RUNNER_TEMP/mavericks-vm-host-uuid"
    STUB_SSH_UP=1 run boot "$BOX"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    u="$(uuid_of)"
    [[ "$u" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]] || { echo "-uuid '$u'"; false; }
    [ "$(cat "$RUNNER_TEMP/mavericks-vm-host-uuid")" = "$u" ]
    [[ "$output" == *"(new, kept in "*"; the one there was not a UUID)"* ]] || { echo "$output"; false; }
}
