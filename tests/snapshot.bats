#!/usr/bin/env bats
#
# The prepared guest: shut down cleanly, then the overlay flattened into a new image
# beside the same firmware.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export PATH="$REPO/tests/stubs:$PATH" STUB_LOG="$BATS_TEST_TMPDIR/stub.log" STUB_SSH_UP=1
    : > "$STUB_LOG"
    export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME/.ssh"; : > "$HOME/.ssh/config"
    export MVM_DATA_DIR="$BATS_TEST_TMPDIR/data" MVM_SHUTDOWN_TIMEOUT=3
    mkdir -p "$MVM_DATA_DIR"; : > "$MVM_DATA_DIR/overlay.qcow2"
    echo 999999 > "$MVM_DATA_DIR/qemu.pid"   # no such process: QEMU has already exited
    BOX="$BATS_TEST_TMPDIR/box"; mkdir -p "$BOX"
    for f in box_0.img OVMF_CODE.fd OVMF_VARS.fd opencore.img; do printf '%s' "$f" > "$BOX/$f"; done
}

@test "the guest is shut down, then the overlay is flattened into the new image" {
    run bash "$REPO/scripts/snapshot.sh" "$BOX" "$BATS_TEST_TMPDIR/prepared"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    sd=$(grep -n '^ssh .*shutdown -h now' "$STUB_LOG" | cut -d: -f1)
    cv=$(grep -n "^qemu-img convert -O qcow2 $MVM_DATA_DIR/overlay.qcow2 $BATS_TEST_TMPDIR/prepared/box_0.img" "$STUB_LOG" | cut -d: -f1)
    [ -n "$sd" ] && [ -n "$cv" ] && [ "$sd" -lt "$cv" ]
}

@test "the firmware travels with the prepared image" {
    run bash "$REPO/scripts/snapshot.sh" "$BOX" "$BATS_TEST_TMPDIR/prepared"
    for f in OVMF_CODE.fd OVMF_VARS.fd opencore.img; do
        cmp "$BOX/$f" "$BATS_TEST_TMPDIR/prepared/$f"
    done
}

@test "a guest that will not power off within the timeout fails, rather than snapshotting a running disk" {
    sleep 30 & echo $! > "$MVM_DATA_DIR/qemu.pid"
    run bash "$REPO/scripts/snapshot.sh" "$BOX" "$BATS_TEST_TMPDIR/prepared"
    kill %1 2>/dev/null
    [ "$status" -ne 0 ]
    run grep -q '^qemu-img convert' "$STUB_LOG"
    [ "$status" -ne 0 ]
}
