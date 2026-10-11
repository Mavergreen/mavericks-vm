#!/usr/bin/env bats
#
# The prepared guest: shut down cleanly, then the overlay written as a delta over the
# layer's disk, beside the layer's firmware.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export PATH="$REPO/tests/stubs:$PATH" STUB_LOG="$BATS_TEST_TMPDIR/stub.log" STUB_SSH_UP=1
    : > "$STUB_LOG"
    export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME/.ssh"; : > "$HOME/.ssh/config"
    export MVM_DATA_DIR="$BATS_TEST_TMPDIR/data" MVM_SHUTDOWN_TIMEOUT=3
    mkdir -p "$MVM_DATA_DIR"; : > "$MVM_DATA_DIR/overlay.qcow2"
    echo 999999 > "$MVM_DATA_DIR/qemu.pid"   # no such process: QEMU has already exited
    BOX="$BATS_TEST_TMPDIR/layer"; mkdir -p "$BOX"
    for f in box_0.img OVMF_CODE.fd OVMF_VARS.fd opencore.img; do printf '%s' "$f" > "$BOX/$f"; done
}

# spec: the prepared image is a delta whose backing file is the literal ../layer/box_0.img, written
#       from the prepared dir so the relative name is stored as given; it resolves when the
#       prepared dir is the layer's sibling, as it is in data-dir
@test "the guest is shut down, then the overlay becomes a delta over the layer, in the prepared dir" {
    run bash "$REPO/scripts/snapshot.sh" "$BOX" "$BATS_TEST_TMPDIR/prepared"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    sd=$(grep -n '^ssh .*shutdown -h now' "$STUB_LOG" | cut -d: -f1)
    cv=$(grep -nxF "qemu-img convert -O qcow2 -F qcow2 -B ../layer/box_0.img $MVM_DATA_DIR/overlay.qcow2 box_0.img" "$STUB_LOG" | cut -d: -f1)
    [ -n "$sd" ] && [ -n "$cv" ] && [ "$sd" -lt "$cv" ] || { cat "$STUB_LOG"; false; }
    [ "$(sed -n "$((cv + 1))p" "$STUB_LOG")" = "cwd $BATS_TEST_TMPDIR/prepared" ] || { cat "$STUB_LOG"; false; }
    [ -f "$BATS_TEST_TMPDIR/prepared/box_0.img" ]
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
