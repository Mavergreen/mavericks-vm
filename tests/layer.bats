#!/usr/bin/env bats
#
# The Aqua Transport layer: the plugin's mavericks-aquatransport box, built over the base box and
# cached as a thin qcow2 delta over the base's disk.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export PATH="$REPO/tests/stubs:$PATH" STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
    : > "$STUB_LOG"
    export MVM_DATA_DIR="$BATS_TEST_TMPDIR/data" MVM_CACHE_DIR="$BATS_TEST_TMPDIR/data/cache"
    mkdir -p "$MVM_DATA_DIR/box" "$BATS_TEST_TMPDIR/z/templates/mavericks-aquatransport"
    printf 'source "qemu" "aquatransport" {}\n' > "$BATS_TEST_TMPDIR/z/templates/mavericks-aquatransport/a.pkr.hcl"
    (cd "$BATS_TEST_TMPDIR/z" && zip -qr ../template.zip templates)
    export STUB_TEMPLATE_ZIP="$BATS_TEST_TMPDIR/template.zip"
    printf basedisk > "$MVM_DATA_DIR/box/box_0.img"
    BASE_ID=0123456789abcdef0123456789abcdef; printf '%s\n' "$BASE_ID" > "$MVM_DATA_DIR/box/image-id"
    BASE="$MVM_DATA_DIR/box"; LAYER="$MVM_DATA_DIR/layer"
}

layer() { bash "$REPO/scripts/layer.sh" "$@"; }

@test "the layer is built over the base box, by the layer template" {
    run layer "$BASE" "$LAYER"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    grep -q "^curl .*_mavericks-aquatransport_template.zip$" "$STUB_LOG"
    grep -q "^packer build .*-var base_box=$BASE" "$STUB_LOG"
}

# spec: convert -B copies every allocated cluster of a standalone source, so it would make the
#       "delta" a whole ~6 GB image; an overlay over the full image, rebased in safe mode onto the
#       base, keeps only the clusters that differ from the base
@test "the delta is an overlay over the full image, rebased onto the base, run in the layer dir" {
    run layer "$BASE" "$LAYER"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    run grep -q '^qemu-img convert' "$STUB_LOG"
    [ "$status" -ne 0 ]
    cr=$(grep -nxF "qemu-img create -q -f qcow2 -F qcow2 -b $MVM_DATA_DIR/layer-full/box_0.img box_0.img" "$STUB_LOG" | cut -d: -f1)
    rb=$(grep -nxF "qemu-img rebase -f qcow2 -F qcow2 -b ../box/box_0.img box_0.img" "$STUB_LOG" | cut -d: -f1)
    [ -n "$cr" ] && [ -n "$rb" ] && [ "$cr" -lt "$rb" ] || { cat "$STUB_LOG"; false; }
    [ "$(sed -n "$((cr + 1))p" "$STUB_LOG")" = "cwd $LAYER" ] || { cat "$STUB_LOG"; false; }
    [ "$(sed -n "$((rb + 1))p" "$STUB_LOG")" = "cwd $LAYER" ] || { cat "$STUB_LOG"; false; }
    [ -f "$LAYER/box_0.img" ]
}

# spec: the delta holds only what the layer changed, and reads as the whole layer guest. This test
#       runs the real qemu-img, which only reads and writes small image files in this test's own
#       $BATS_TEST_TMPDIR: it cannot reach the host. Every other command is still a stub.
@test "with the real qemu-img, the delta is small, backed by ../box/box_0.img, and reads as the full image" {
    [ -x /usr/bin/qemu-img ] || skip "no /usr/bin/qemu-img on this machine"
    real="$BATS_TEST_TMPDIR/real"; mkdir -p "$real"; ln -s /usr/bin/qemu-img "$real/qemu-img"
    raw="$BATS_TEST_TMPDIR/disk.raw"; full="$BATS_TEST_TMPDIR/full.qcow2"
    head -c 16M /dev/urandom > "$raw"
    rm "$BASE/box_0.img"
    /usr/bin/qemu-img convert -q -f raw -O qcow2 "$raw" "$BASE/box_0.img"
    # the layer build changes one 64 KiB cluster of the 256 the base holds
    head -c 64K /dev/urandom | dd of="$raw" bs=64K seek=100 conv=notrunc status=none
    /usr/bin/qemu-img convert -q -f raw -O qcow2 "$raw" "$full"
    STUB_PACKER_DISK="$full" PATH="$real:$PATH" run layer "$BASE" "$LAYER"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    run /usr/bin/qemu-img info --output=json "$LAYER/box_0.img"
    [[ "$output" == *'"backing-filename": "../box/box_0.img"'* ]] || { echo "$output"; false; }
    delta_size="$(stat -c %s "$LAYER/box_0.img")" full_size="$(stat -c %s "$full")"
    echo "delta $delta_size bytes, full $full_size bytes" >&3
    [ "$delta_size" -lt "$((full_size / 8))" ] || { echo "delta $delta_size bytes, full $full_size bytes"; false; }
    # the full image is gone; the delta reads through its backing file, the base
    [ ! -e "$MVM_DATA_DIR/layer-full" ]
    run /usr/bin/qemu-img compare "$LAYER/box_0.img" "$full"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [[ "$output" == *"Images are identical"* ]] || false
}

# spec: the real-qemu-img test above skips where there is no qemu-img; the release's unit tests
#       install it, so there it runs
@test "the release's unit tests install qemu-img, so the real-qemu-img delta test runs there" {
    grep -q '^        run: sudo apt-get update -qq && sudo apt-get install -y -qq bats shellcheck qemu-utils$' \
        "$REPO/.github/workflows/release.yml"
}

# spec: a delta is bound to the bytes of the image under it; the ids say which image that is
@test "the layer gets a fresh image-id, and the base's image-id as its backing-id" {
    run layer "$BASE" "$LAYER"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$(cat "$LAYER/backing-id")" = "$BASE_ID" ]
    first="$(cat "$LAYER/image-id")"
    [[ "$first" =~ ^[0-9a-f]{32}$ ]] || false
    [ "$first" != "$BASE_ID" ]
    rm -rf "$LAYER"
    run layer "$BASE" "$LAYER"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$(cat "$LAYER/image-id")" != "$first" ]
}

@test "a base with no image-id fails naming the layer, before anything is built" {
    rm "$BASE/image-id"
    run layer "$BASE" "$LAYER"
    [ "$status" -eq 1 ]
    [[ "$output" == *"::error title=mavericks-vm::building the layer image: the base has no image-id"* ]] || false
    run grep -q '^packer' "$STUB_LOG"
    [ "$status" -ne 0 ]
    [ ! -e "$LAYER" ]
}

@test "the firmware comes from the layer's own build" {
    run layer "$BASE" "$LAYER"
    [ "$status" -eq 0 ]
    for f in OVMF_CODE.fd OVMF_VARS.fd opencore.img; do
        [ -f "$LAYER/$f" ] || { echo "missing $f"; false; }
    done
}

# spec: docs "Safety" -- the decrypted guest leaves the disk when the step ends
@test "the full image is deleted afterwards" {
    run layer "$BASE" "$LAYER"
    [ "$status" -eq 0 ]
    [ ! -e "$MVM_DATA_DIR/layer-full" ]
}

# The base is compared by name, size, mode, mtime and content before and after.
base_state() { (cd "$BASE" && find . -printf '%p %y %s %m %T@\n' | sort; find . -type f | sort | xargs cat | cksum); }

@test "the base is never written" {
    printf oc > "$BASE/opencore.img"
    before="$(base_state)"
    sleep 1
    run layer "$BASE" "$LAYER"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$before" = "$(base_state)" ] || { echo "base changed"; false; }
}

# spec: a stale full image from an earlier run must not be unpacked over or beside
@test "a leftover in layer-full does not survive into the new layer build" {
    mkdir -p "$MVM_DATA_DIR/layer-full"; printf stale > "$MVM_DATA_DIR/layer-full/stale.img"
    cat > "$BATS_TEST_TMPDIR/qemu-img" <<'X'
#!/bin/bash
[ "$1" = create ] || exit 0
while [ $# -gt 0 ] && [ "$1" != -b ]; do shift; done
[ $# -ge 2 ] || { echo "fake qemu-img: create without -b <backing>" >&2; exit 1; }
ls -A "$(dirname "$2")" > "$LISTING"
exit 0
X
    chmod +x "$BATS_TEST_TMPDIR/qemu-img"
    export LISTING="$BATS_TEST_TMPDIR/listing"
    PATH="$BATS_TEST_TMPDIR:$PATH" run layer "$BASE" "$LAYER"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    grep -qx box_0.img "$LISTING"
    ! grep -qx stale.img "$LISTING" || false
}

@test "a failed build exits 1 naming the layer, and leaves neither the full image nor a layer dir" {
    STUB_PACKER_FAIL=1 run layer "$BASE" "$LAYER"
    [ "$status" -eq 1 ]
    [[ "$output" == *"::error title=mavericks-vm::building the layer image failed"* ]] || false
    # one ::error per failure: build.sh's own lines are plain
    [ "$(grep -c '::error' <<< "$output")" -eq 1 ] || { echo "$output"; false; }
    [ ! -e "$MVM_DATA_DIR/layer-full" ]
    [ ! -e "$LAYER" ]
}

@test "a failed delta exits 1 naming the layer, and leaves neither the full image nor a layer dir" {
    cat > "$BATS_TEST_TMPDIR/qemu-img" <<'X'
#!/bin/bash
exit 1
X
    chmod +x "$BATS_TEST_TMPDIR/qemu-img"
    PATH="$BATS_TEST_TMPDIR:$PATH" run layer "$BASE" "$LAYER"
    [ "$status" -eq 1 ]
    [[ "$output" == *"::error title=mavericks-vm::building the layer image: making the overlay over the full image failed"* ]] || false
    [ ! -e "$MVM_DATA_DIR/layer-full" ]
    [ ! -e "$LAYER" ]
}

@test "a failed rebase exits 1 naming the layer and the step, and leaves neither the full image nor a layer dir" {
    cat > "$BATS_TEST_TMPDIR/qemu-img" <<'X'
#!/bin/bash
[ "$1" != rebase ] || exit 1
touch "${!#}"
X
    chmod +x "$BATS_TEST_TMPDIR/qemu-img"
    PATH="$BATS_TEST_TMPDIR:$PATH" run layer "$BASE" "$LAYER"
    [ "$status" -eq 1 ]
    [[ "$output" == *"::error title=mavericks-vm::building the layer image: rebasing the delta onto the base failed"* ]] || false
    [ "$(grep -c '::error' <<< "$output")" -eq 1 ] || { echo "$output"; false; }
    [ ! -e "$MVM_DATA_DIR/layer-full" ]
    [ ! -e "$LAYER" ]
}

@test "a base that is not the layer's sibling box is refused, since the backing would not resolve" {
    run layer "$MVM_DATA_DIR/elsewhere" "$LAYER"
    [ "$status" -eq 2 ]
    [[ "$output" == *"../box"* ]] || false
    [ ! -e "$LAYER" ]
}

@test "arguments are required" {
    run layer "$BASE"
    [ "$status" -eq 2 ]
}

@test "a layer dir that already holds anything is refused, and left as it was" {
    mkdir -p "$LAYER"; printf keep > "$LAYER/precious"
    run layer "$BASE" "$LAYER"
    [ "$status" -eq 2 ]
    [[ "$output" == *"not empty"* ]] || false
    [ "$(cat "$LAYER/precious")" = keep ]
}

@test "a failed build keeps an empty layer dir that was there before, and removes what it made" {
    mkdir -p "$LAYER"
    STUB_PACKER_FAIL=1 run layer "$BASE" "$LAYER"
    [ "$status" -eq 1 ]
    [ -d "$LAYER" ]
    [ -z "$(ls -A "$LAYER")" ]
}

@test "a failed delta removes the files it wrote from an empty layer dir that was there before" {
    mkdir -p "$LAYER"
    printf '#!/bin/bash\nexit 1\n' > "$BATS_TEST_TMPDIR/qemu-img"; chmod +x "$BATS_TEST_TMPDIR/qemu-img"
    PATH="$BATS_TEST_TMPDIR:$PATH" run layer "$BASE" "$LAYER"
    [ "$status" -eq 1 ]
    [ -d "$LAYER" ]
    [ -z "$(ls -A "$LAYER")" ]
}

@test "a layer dir that cannot be read is not taken for an empty one" {
    [ "$(id -u)" -ne 0 ] || skip "root reads everything"
    mkdir -p "$LAYER"; chmod 000 "$LAYER"
    run layer "$BASE" "$LAYER"
    chmod 755 "$LAYER"
    [ "$status" -eq 2 ]
    [[ "$output" == *"cannot read"* ]] || false
}
