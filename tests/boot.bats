#!/usr/bin/env bats
#
# Booting the cached guest the way the box's own Vagrantfile does, from a
# throwaway overlay, and refusing a runner without room before starting.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export PATH="$REPO/tests/stubs:$PATH" STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
    export STUB_QEMU_ARGV="$BATS_TEST_TMPDIR/qemu.argv" HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME"; : > "$STUB_LOG"
    export MVM_DATA_DIR="$BATS_TEST_TMPDIR/data" MVM_MEM=4096 MVM_CPU=2 \
        MVM_CPU_MODEL='Penryn,+ssse3,+sse4.1,+sse4.2' MVM_NAT='tcp:8080:80 udp:8081:80' \
        MVM_KVM=/dev/null MVM_SSH_TIMEOUT=2 MVM_SSH_INTERVAL=1
    BOX="$BATS_TEST_TMPDIR/box"; mkdir -p "$BOX"
    for f in box_0.img OVMF_CODE.fd OVMF_VARS.fd opencore.img; do : > "$BOX/$f"; done
}

boot() { bash "$REPO/scripts/boot.sh" "$@"; }
argv_has() { grep -qxF -- "$1" "$STUB_QEMU_ARGV"; }

@test "QEMU gets the box's machine, CPU, memory, cores and devices" {
    STUB_SSH_UP=1 run boot "$BOX"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    argv_has q35,vmport=off,accel=kvm
    argv_has 'Penryn,+ssse3,+sse4.1,+sse4.2'
    argv_has 4096M
    argv_has 2
    argv_has "if=pflash,format=raw,unit=0,readonly=on,file=$BOX/OVMF_CODE.fd"
    argv_has "id=opencore,if=none,format=raw,snapshot=on,file=$BOX/opencore.img"
    argv_has 'usb-storage,bus=usb.0,drive=opencore'
    argv_has 'ich9-usb-ehci1,id=usb,bus=pcie.0,addr=0x1d.7,multifunction=on'
    argv_has 'ide-hd,bus=ide.0,drive=target'
    argv_has 'e1000-82545em,netdev=net0'
}

@test "the cached disk is a read-only backing file; writes go to an overlay under data-dir" {
    STUB_SSH_UP=1 run boot "$BOX"
    [ "$status" -eq 0 ]
    grep -q "^qemu-img create -f qcow2 -F qcow2 -b $BOX/box_0.img $MVM_DATA_DIR/" "$STUB_LOG"
    grep -q "^id=target,if=none,format=qcow2,file=$MVM_DATA_DIR/" "$STUB_QEMU_ARGV"
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

@test "a runner without /dev/kvm is refused, by name" {
    MVM_KVM=/nonexistent run boot "$BOX"
    [ "$status" -ne 0 ]
    [[ "$output" == *"/nonexistent"* ]] || false
}

@test "space: a data-dir with less room than needed is refused, naming both numbers" {
    mkdir -p "$MVM_DATA_DIR"
    MVM_SPACE_AVAILABLE_KIB=1048576 run bash "$REPO/scripts/space.sh" hit
    [ "$status" -ne 0 ]
    [[ "$output" == *"1 GiB"* ]] || false
    [[ "$output" == *"$MVM_DATA_DIR"* ]] || false
    MVM_SPACE_AVAILABLE_KIB=$((100*1024*1024)) run bash "$REPO/scripts/space.sh" miss
    [ "$status" -eq 0 ]
}
