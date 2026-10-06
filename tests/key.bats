#!/usr/bin/env bats
#
# The cache key: what the cached guest is made of, known without building it
# (the spec's "The cache: key, encryption, storage").

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    ROOT="$BATS_TEST_TMPDIR/root"
    mkdir -p "$ROOT/components/packer-plugin-macosx" "$ROOT/scripts"
    printf 'v0.20261005.2\n' > "$ROOT/components/packer-plugin-macosx/version"
    printf 'updates = "security"\nsmbios = "iMac14,2"\nuser = "vagrant"\n' > "$ROOT/box.pkrvars.hcl"
    printf '1\n' > "$ROOT/scripts/guest-recipe"
    export MVM_ROOT="$ROOT"
    unset MVM_PREPARE MVM_CACHE_AFTER_PREPARE_SUFFIX
}

key() { bash "$REPO/scripts/key.sh" "$@"; }

@test "the key is 64 hex digits, and the same inputs give the same key" {
    run key
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9a-f]{64}$ ]] || false
    first="$output"
    run key
    [ "$output" = "$first" ]
}

@test "the key moves with the plugin release, each box setting and the guest recipe" {
    base="$(key)"
    printf 'v0.20261005.3\n' > "$ROOT/components/packer-plugin-macosx/version"
    [ "$(key)" != "$base" ]
    printf 'v0.20261005.2\n' > "$ROOT/components/packer-plugin-macosx/version"
    [ "$(key)" = "$base" ]
    for change in 's/security/none/' 's/iMac14,2/MacPro5,1/' 's/vagrant/builder/'; do
        cp "$ROOT/box.pkrvars.hcl" "$BATS_TEST_TMPDIR/vars.bak"
        sed -i "$change" "$ROOT/box.pkrvars.hcl"
        [ "$(key)" != "$base" ] || { echo "unmoved by $change"; false; }
        cp "$BATS_TEST_TMPDIR/vars.bak" "$ROOT/box.pkrvars.hcl"
    done
    printf '2\n' > "$ROOT/scripts/guest-recipe"
    [ "$(key)" != "$base" ]
}

@test "runtime inputs do not move the key: they reuse the same guest" {
    base="$(key)"
    run env MVM_MEM=8192 MVM_CPU=4 MVM_CPU_MODEL=Nehalem MVM_NAT='tcp:8080:80' MVM_SYNC=scp bash "$REPO/scripts/key.sh"
    [ "$output" = "$base" ]
}

@test "the prepared key differs from the base, and moves with prepare and the suffix" {
    base="$(key)"
    MVM_PREPARE='echo one' run key --prepared
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9a-f]{64}$ ]] || false
    p1="$output"
    [ "$p1" != "$base" ]
    MVM_PREPARE='echo two' run key --prepared
    [ "$output" != "$p1" ]
    MVM_PREPARE='echo one' MVM_CACHE_AFTER_PREPARE_SUFFIX=x run key --prepared
    [ "$output" != "$p1" ]
    MVM_PREPARE='echo one' run key --prepared
    [ "$output" = "$p1" ]
}

@test "a missing or empty pin is an error, not a key" {
    : > "$ROOT/components/packer-plugin-macosx/version"
    run key
    [ "$status" -ne 0 ]
    [[ "$output" == *"packer-plugin-macosx"* ]] || false
}

@test "the repo's own box.pkrvars.hcl, guest recipe and pin exist and produce a key" {
    MVM_ROOT="$REPO" run key
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9a-f]{64}$ ]] || false
}
