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

@test "the delta is made with the exact convert line, run in the layer dir" {
    run layer "$BASE" "$LAYER"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    grep -qxF "qemu-img convert -O qcow2 -F qcow2 -B ../box/box_0.img $MVM_DATA_DIR/layer-full/box_0.img box_0.img" "$STUB_LOG"
    grep -qxF "cwd $LAYER" "$STUB_LOG"
    [ -f "$LAYER/box_0.img" ]
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
    [[ "$output" == *"::error title=mavericks-vm::building the Aqua Transport layer"* ]] || false
    [[ "$output" == *"image-id"* ]] || false
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
ls -A "$(dirname "$8")" > "$LISTING"
exit 0
X
    chmod +x "$BATS_TEST_TMPDIR/qemu-img"
    export LISTING="$BATS_TEST_TMPDIR/listing"
    PATH="$BATS_TEST_TMPDIR:$PATH" run layer "$BASE" "$LAYER"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    grep -qx box_0.img "$LISTING"
    ! grep -qx stale.img "$LISTING"
}

@test "a failed build exits 1 naming the layer, and leaves neither the full image nor a layer dir" {
    STUB_PACKER_FAIL=1 run layer "$BASE" "$LAYER"
    [ "$status" -eq 1 ]
    [[ "$output" == *"::error title=mavericks-vm::building the Aqua Transport layer"* ]] || false
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
    [[ "$output" == *"::error title=mavericks-vm::building the Aqua Transport layer"* ]] || false
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
