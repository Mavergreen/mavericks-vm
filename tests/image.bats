#!/usr/bin/env bats
#
# The cached guest in the registry: encrypted on push, decrypted on pull, by
# key; the key (an age identity) and the token never on a command line.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export PATH="$REPO/tests/stubs:$PATH"
    export STUB_REGISTRY="$BATS_TEST_TMPDIR/registry" STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
    mkdir -p "$STUB_REGISTRY"; : > "$STUB_LOG"
    export MVM_IMAGE_KEY='AGE-SECRET-KEY-1TESTSECRETNEVERINARGV'
    export MVM_TOKEN='ghp_tokennotinargv' GITHUB_ACTOR=someone
    export MVM_REGISTRY=ghcr.io/mavergreen/mavericks-vm-images
    export MVM_DATA_DIR="$BATS_TEST_TMPDIR/data"
    # spec: tests/stubs_safety.bats -- image.sh's work dir, with no data dir yet, is under TMPDIR,
    #       where the stubs may write: the test's own tmp dir, never this machine's /tmp
    export TMPDIR="$BATS_TEST_TMPDIR"
    BOX="$BATS_TEST_TMPDIR/box"; mkdir -p "$BOX"
    printf 'disk' > "$BOX/box_0.img"; printf 'code' > "$BOX/OVMF_CODE.fd"
    printf 'vars' > "$BOX/OVMF_VARS.fd"; printf 'oc' > "$BOX/opencore.img"
    K=$(printf '%064d' 7)
}

image() { bash "$REPO/scripts/image.sh" "$@"; }

@test "push then pull round-trips the guest's files" {
    run image push "$K" "$BOX"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    out="$BATS_TEST_TMPDIR/out"
    run image pull "$K" "$out"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    diff -r "$BOX" "$out"
}

@test "a key nobody pushed is a miss: exit 3, and nothing in the directory" {
    out="$BATS_TEST_TMPDIR/out"
    run image pull "$K" "$out"
    [ "$status" -eq 3 ]
    [ -z "$(ls -A "$out" 2>/dev/null)" ]
}

@test "a corrupt blob fails naming the key, and leaves nothing behind" {
    mkdir -p "$STUB_REGISTRY/$K"; printf 'garbage\n' > "$STUB_REGISTRY/$K/blob"
    out="$BATS_TEST_TMPDIR/out"
    run image pull "$K" "$out"
    [ "$status" -ne 0 ]; [ "$status" -ne 3 ]
    [[ "$output" == *"$K"* ]] || false
    [ -z "$(ls -A "$out" 2>/dev/null)" ]
}

@test "a blob encrypted for another key does not decrypt" {
    run image push "$K" "$BOX"
    out="$BATS_TEST_TMPDIR/out"
    MVM_IMAGE_KEY='AGE-SECRET-KEY-1SOMEONEELSE' run image pull "$K" "$out"
    [ "$status" -ne 0 ]; [ "$status" -ne 3 ]
    [ -z "$(ls -A "$out" 2>/dev/null)" ]
}

# spec: a skipped push exits 4, so main.sh knows the image under the key is not the one it built,
#       and caches nothing it made over that one (task 3 re-review, minor 1)
@test "a push to a key that already exists is skipped, says so, and exits 4" {
    mkdir -p "$STUB_REGISTRY/$K"; printf 'theirs\n' > "$STUB_REGISTRY/$K/blob"
    run image push "$K" "$BOX"
    [ "$status" -eq 4 ]
    [[ "$output" == *"already"* ]] || false
    [ "$(cat "$STUB_REGISTRY/$K/blob")" = theirs ]
}

# spec: a delta is bound to the bytes of the image under it; when main.sh throws away a cached
#       image (stale, or over a different image) and rebuilds it, push-if-absent would keep the
#       stale one under the key, so the rebuilt one is pushed with --replace
@test "push --replace overwrites a guest already under the key, without asking whether it is there" {
    mkdir -p "$STUB_REGISTRY/$K"; printf 'theirs\n' > "$STUB_REGISTRY/$K/blob"
    run image push --replace "$K" "$BOX"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [[ "$output" == *"replaced"* ]] || false
    run grep -q '^oras manifest fetch' "$STUB_LOG"
    [ "$status" -ne 0 ]
    run image pull "$K" "$BATS_TEST_TMPDIR/out"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    diff -r "$BOX" "$BATS_TEST_TMPDIR/out"
}

@test "push --replace to a key nobody pushed pushes it" {
    run image push --replace "$K" "$BOX"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    run image pull "$K" "$BATS_TEST_TMPDIR/out"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    diff -r "$BOX" "$BATS_TEST_TMPDIR/out"
}

@test "--replace is for push only, and still takes a key and a dir" {
    run image pull --replace "$K" "$BATS_TEST_TMPDIR/out"
    [ "$status" -eq 2 ]
    run image push --replace "$K"
    [ "$status" -eq 2 ]
    run image push "$K" "$BOX" --replace
    [ "$status" -eq 2 ]
}

@test "neither the key nor the token reaches any command line or any output" {
    run image push "$K" "$BOX"
    run image pull "$K" "$BATS_TEST_TMPDIR/out"
    run grep -F -e "$MVM_IMAGE_KEY" -e "$MVM_TOKEN" "$STUB_LOG"
    [ "$status" -ne 0 ] || { echo "leaked into argv: $output"; false; }
    run bash -c "bash '$REPO/scripts/image.sh' push '$K' '$BOX' 2>&1; bash '$REPO/scripts/image.sh' pull '$K' '$BATS_TEST_TMPDIR/out2' 2>&1"
    [[ "$output" != *"$MVM_IMAGE_KEY"* ]] || false
    [[ "$output" != *"$MVM_TOKEN"* ]] || false
}

@test "an unknown subcommand or a malformed key is a usage error" {
    run image fetch "$K" "$BOX"
    [ "$status" -eq 2 ]
    run image pull notakey "$BOX"
    [ "$status" -eq 2 ]
}

# spec: GHCR cut three jobs' downloads off at once mid-transfer while a fourth, the same minute,
#       went through (Actions run 37620368526): a transfer the registry drops is tried again
@test "a pull the registry cuts off is tried again, and the guest arrives" {
    run image push "$K" "$BOX"
    STUB_ORAS_FAIL_PULLS=2 MVM_RETRY_WAIT=0 run image pull "$K" "$BATS_TEST_TMPDIR/out"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    diff -r "$BOX" "$BATS_TEST_TMPDIR/out"
    [ "$(grep -c '^oras pull' "$STUB_LOG")" -eq 3 ]
}

@test "a pull cut off three times fails, with the registry's own error" {
    run image push "$K" "$BOX"
    STUB_ORAS_FAIL_PULLS=3 MVM_RETRY_WAIT=0 run image pull "$K" "$BATS_TEST_TMPDIR/out"
    [ "$status" -ne 0 ]; [ "$status" -ne 3 ]
    [[ "$output" == *"PROTOCOL_ERROR"* ]] || false
    [ -z "$(ls -A "$BATS_TEST_TMPDIR/out" 2>/dev/null)" ]
}

@test "a push the registry cuts off is tried again" {
    STUB_ORAS_FAIL_PUSHES=1 MVM_RETRY_WAIT=0 run image push "$K" "$BOX"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ -f "$STUB_REGISTRY/$K/blob" ]
}

# spec: retries alone cannot help a transfer that stalls without failing: each attempt has a
#       time limit, and a stalled one is cut off and tried again
@test "a pull that stalls is cut off and tried again" {
    run image push "$K" "$BOX"
    start=$SECONDS
    STUB_ORAS_STALL_PULLS=1 MVM_TRANSFER_TIMEOUT=2 MVM_RETRY_WAIT=0 run image pull "$K" "$BATS_TEST_TMPDIR/out"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ $((SECONDS - start)) -le 10 ] || { echo "took $((SECONDS - start))s"; false; }
    [[ "$output" == *"2s"* ]] || false
    diff -r "$BOX" "$BATS_TEST_TMPDIR/out"
}

@test "file store: push encrypts to the blob, pull decrypts it, and the registry is never touched" {
    export MVM_STORE=file MVM_BLOB_DIR="$BATS_TEST_TMPDIR/blob"
    run image push "$K" "$BOX"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    head -1 "$MVM_BLOB_DIR/$K.tar.zst.age" | grep -q '^STUBAGE recipient='
    out="$BATS_TEST_TMPDIR/out"
    run image pull "$K" "$out"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    diff -r "$BOX" "$out"
    run grep -q '^oras' "$STUB_LOG"
    [ "$status" -ne 0 ]
}

@test "file store: no blob is a miss" {
    export MVM_STORE=file MVM_BLOB_DIR="$BATS_TEST_TMPDIR/blob"
    run image pull "$K" "$BATS_TEST_TMPDIR/out"
    [ "$status" -eq 3 ]
    run grep -q '^oras' "$STUB_LOG"
    [ "$status" -ne 0 ]
}

@test "file store: a blob another key encrypted is a miss, and is removed so a push replaces it" {
    export MVM_STORE=file MVM_BLOB_DIR="$BATS_TEST_TMPDIR/blob"
    run image push "$K" "$BOX"
    export MVM_IMAGE_KEY='AGE-SECRET-KEY-1SOMEONEELSE'
    run image pull "$K" "$BATS_TEST_TMPDIR/out"
    [ "$status" -eq 3 ] || { echo "$output"; false; }
    [[ "$output" == *"another key"* ]] || false
    [ -z "$(ls -A "$BATS_TEST_TMPDIR/out" 2>/dev/null)" ]
    [ ! -e "$MVM_BLOB_DIR/$K.tar.zst.age" ]
    run image push "$K" "$BOX"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    run image pull "$K" "$BATS_TEST_TMPDIR/out"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    diff -r "$BOX" "$BATS_TEST_TMPDIR/out"
}

@test "file store: a push to a key that already has a blob is skipped, says so, and exits 4" {
    export MVM_STORE=file MVM_BLOB_DIR="$BATS_TEST_TMPDIR/blob"
    mkdir -p "$MVM_BLOB_DIR"; printf 'theirs\n' > "$MVM_BLOB_DIR/$K.tar.zst.age"
    run image push "$K" "$BOX"
    [ "$status" -eq 4 ]
    [[ "$output" == *"already"* ]] || false
    [ "$(cat "$MVM_BLOB_DIR/$K.tar.zst.age")" = theirs ]
}

@test "file store: push --replace writes over the blob already under the key" {
    export MVM_STORE=file MVM_BLOB_DIR="$BATS_TEST_TMPDIR/blob"
    mkdir -p "$MVM_BLOB_DIR"; printf 'theirs\n' > "$MVM_BLOB_DIR/$K.tar.zst.age"
    run image push --replace "$K" "$BOX"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [[ "$output" == *"replaced"* ]] || false
    run image pull "$K" "$BATS_TEST_TMPDIR/out"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    diff -r "$BOX" "$BATS_TEST_TMPDIR/out"
}

@test "a guest that appears under the key while the push encrypts is kept, and the push exits 4" {
    # an oras of this test's own: the first "is it there?" says no, and another run pushes just then
    fake="$BATS_TEST_TMPDIR/fake"; mkdir -p "$fake"
    cat > "$fake/oras" <<X
#!/bin/bash
if [ "\$1 \$2" = "manifest fetch" ] && [ ! -e "$BATS_TEST_TMPDIR/asked" ]; then
    : > "$BATS_TEST_TMPDIR/asked"
    mkdir -p "$STUB_REGISTRY/$K"; printf 'theirs\\n' > "$STUB_REGISTRY/$K/blob"
    echo "Error: not found" >&2; exit 1
fi
exec "$REPO/tests/stubs/oras" "\$@"
X
    chmod +x "$fake/oras"
    PATH="$fake:$PATH" run image push "$K" "$BOX"
    [ "$status" -eq 4 ] || { echo "$output"; false; }
    [[ "$output" == *"meanwhile"* ]] || false
    [ "$(cat "$STUB_REGISTRY/$K/blob")" = theirs ]
}
