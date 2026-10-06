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

@test "a push to a key that already exists is skipped, and says so" {
    mkdir -p "$STUB_REGISTRY/$K"; printf 'theirs\n' > "$STUB_REGISTRY/$K/blob"
    run image push "$K" "$BOX"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already"* ]] || false
    [ "$(cat "$STUB_REGISTRY/$K/blob")" = theirs ]
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
