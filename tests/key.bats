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
    printf '1\n' > "$ROOT/scripts/layer-recipe"
    export MVM_ROOT="$ROOT"
    export PATH="$REPO/tests/stubs:$PATH" STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
    : > "$STUB_LOG"
    export STUB_BASE_RECIPE="$(printf 'a%.0s' {1..64})"
    unset MVM_PREPARE MVM_CACHE_AFTER_PREPARE_SUFFIX
}

key() { bash "$REPO/scripts/key.sh" "$@"; }

@test "the key is 64 hex digits, and the same inputs give the same key" {
    run key --base
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9a-f]{64}$ ]] || false
    first="$output"
    run key --base
    [ "$output" = "$first" ]
}

@test "the base key moves with each box setting, the guest recipe and the base recipe" {
    base="$(key --base)"
    for change in 's/security/none/' 's/iMac14,2/MacPro5,1/' 's/vagrant/builder/'; do
        cp "$ROOT/box.pkrvars.hcl" "$BATS_TEST_TMPDIR/vars.bak"
        sed -i "$change" "$ROOT/box.pkrvars.hcl"
        [ "$(key --base)" != "$base" ] || { echo "unmoved by $change"; false; }
        cp "$BATS_TEST_TMPDIR/vars.bak" "$ROOT/box.pkrvars.hcl"
    done
    [ "$(key --base)" = "$base" ]
    printf '2\n' > "$ROOT/scripts/guest-recipe"
    [ "$(key --base)" != "$base" ]
}

@test "the base key does not move when only the plugin version moves and its base recipe does not" {
    base="$(key --base)"
    printf 'v0.20261005.3\n' > "$ROOT/components/packer-plugin-macosx/version"
    [ "$(key --base)" = "$base" ]
}

@test "the base key moves when the base recipe moves" {
    base="$(key --base)"
    STUB_BASE_RECIPE="$(printf 'b%.0s' {1..64})" run key --base
    [ "$status" -eq 0 ]
    [ "$output" != "$base" ]
}

@test "the base recipe is fetched from the pinned release's asset, with a bounded curl" {
    key --base
    grep -qxF 'curl https://github.com/Mavergreen/packer-plugin-macosx/releases/download/v0.20261005.2/packer-plugin-macosx_v0.20261005.2_mavericks_base_recipe.txt' "$STUB_LOG"
    grep -q 'curl-args -fsSL --retry 3 --max-time 60 ' "$STUB_LOG"
}

@test "the layer key moves when the plugin version moves" {
    layer="$(key --layer)"
    [[ "$layer" =~ ^[0-9a-f]{64}$ ]] || false
    [ "$layer" != "$(key --base)" ]
    printf 'v0.20261005.3\n' > "$ROOT/components/packer-plugin-macosx/version"
    [ "$(key --layer)" != "$layer" ]
    printf 'v0.20261005.2\n' > "$ROOT/components/packer-plugin-macosx/version"
    [ "$(key --layer)" = "$layer" ]
}

@test "the layer key moves when the base key moves" {
    layer="$(key --layer)"
    printf '2\n' > "$ROOT/scripts/guest-recipe"
    [ "$(key --layer)" != "$layer" ]
}

# spec: the layer recipe is this repo's lever on the layer alone: moved when the way this Action
#       makes the layer changes, it makes the layer again over the cached base
@test "the layer key moves when the layer recipe moves, and the base key does not" {
    base="$(key --base)" layer="$(key --layer)"
    MVM_PREPARE='echo one' run key --prepared
    prepared="$output"
    printf '2\n' > "$ROOT/scripts/layer-recipe"
    [ "$(key --layer)" != "$layer" ] || { echo "the layer key ignores the layer recipe"; false; }
    [ "$(key --base)" = "$base" ] || { echo "the base key moved with the layer recipe"; false; }
    MVM_PREPARE='echo one' run key --prepared
    [ "$output" != "$prepared" ]
}

@test "a missing or empty layer recipe fails the layer and prepared keys, naming the file" {
    for content in absent ''; do
        if [ "$content" = absent ]; then rm -f "$ROOT/scripts/layer-recipe"; else printf ' \n' > "$ROOT/scripts/layer-recipe"; fi
        for m in --layer --prepared; do
            MVM_PREPARE=x run key $m
            [ "$status" -ne 0 ] || { echo "$m ($content): status 0: $output"; false; }
            [[ "$output" == *"no layer recipe in $ROOT/scripts/layer-recipe"* ]] || { echo "$output"; false; }
        done
    done
}

# spec: the warmer builds the cached guest when its key moves, so it runs on a push that moves any
#       of the repo's files the keys are made of
@test "the warmer runs on a push to any file the keys are made of" {
    for f in components/packer-plugin-macosx/version box.pkrvars.hcl scripts/guest-recipe scripts/layer-recipe; do
        grep -qxF "      - $f" "$REPO/.github/workflows/warmer.yml" || { echo "warmer.yml misses $f"; false; }
    done
}

@test "a missing base-recipe asset fails, naming the release and the asset, and never falls back" {
    STUB_BASE_RECIPE= run key --base
    [ "$status" -ne 0 ]
    [[ "$output" == *"v0.20261005.2"* ]] || false
    [[ "$output" == *"packer-plugin-macosx_v0.20261005.2_mavericks_base_recipe.txt"* ]] || false
}

@test "a missing base-recipe asset fails the layer and prepared keys too, not only the base" {
    for m in --layer --prepared; do
        STUB_BASE_RECIPE= MVM_PREPARE=x run key $m
        [ "$status" -ne 0 ] || { echo "$m: status 0: $output"; false; }
        [[ "$output" == *"mavericks_base_recipe.txt"* ]] || false
    done
}

@test "a recipe that is not 64 hex digits fails" {
    for bad in abc "$(printf 'A%.0s' {1..64})" "$(printf 'a%.0s' {1..63})" "$(printf 'a%.0s' {1..65})" "$(printf 'g%.0s' {1..64})"; do
        STUB_BASE_RECIPE="$bad" run key --base
        [ "$status" -ne 0 ] || { echo "accepted: $bad"; false; }
        [[ "$output" == *"mavericks_base_recipe.txt"* ]] || false
    done
}

@test "a recipe split across two lines fails" {
    STUB_BASE_RECIPE="$(printf 'a%.0s' {1..32})
$(printf 'a%.0s' {1..32})" run key --base
    [ "$status" -ne 0 ]
    [[ "$output" == *"mavericks_base_recipe.txt"* ]] || false
}

# spec: key.sh --layer and --prepared compute the base key, and with it fetch the base recipe; a
#       caller that has fetched it once (action.yml's key step, main.sh) hands it on in MVM_BASE_RECIPE
@test "--recipe prints the base recipe it fetched" {
    run key --recipe
    [ "$status" -eq 0 ]
    [ "$output" = "$STUB_BASE_RECIPE" ]
    grep -q '^curl ' "$STUB_LOG"
}

@test "a base recipe in MVM_BASE_RECIPE is used and nothing is fetched, for every key" {
    want="$(key --prepared)"; base="$(key --base)"; layer="$(key --layer)"
    : > "$STUB_LOG"
    export MVM_BASE_RECIPE="$STUB_BASE_RECIPE"
    export STUB_BASE_RECIPE=
    [ "$(key --base)" = "$base" ]
    [ "$(key --layer)" = "$layer" ]
    [ "$(key --recipe)" = "$MVM_BASE_RECIPE" ]
    [ ! -s "$STUB_LOG" ] || { cat "$STUB_LOG"; false; }
    [ -n "$want" ]
}

@test "a base recipe in MVM_BASE_RECIPE moves the keys as the fetched one would" {
    base="$(key --base)"
    MVM_BASE_RECIPE="$(printf 'b%.0s' {1..64})" run key --base
    [ "$status" -eq 0 ]
    [ "$output" != "$base" ]
}

@test "an MVM_BASE_RECIPE that is not one line of 64 hex digits fails, and is not fetched around" {
    for bad in abc "$(printf 'A%.0s' {1..64})" "$(printf 'a%.0s' {1..65})"; do
        MVM_BASE_RECIPE="$bad" run key --base
        [ "$status" -ne 0 ] || { echo "accepted: $bad"; false; }
        [[ "$output" == *"MVM_BASE_RECIPE"* ]] || false
    done
    ! grep -q '^curl ' "$STUB_LOG" || false
}

@test "no flag is a usage error" {
    run key
    [ "$status" -eq 2 ]
    [[ "$output" == *"usage"* ]] || false
    run key --bogus
    [ "$status" -eq 2 ]
}

@test "the prepared key moves when the layer key moves" {
    MVM_PREPARE='echo one' run key --prepared
    p1="$output"
    printf 'v0.20261005.3\n' > "$ROOT/components/packer-plugin-macosx/version"
    MVM_PREPARE='echo one' run key --prepared
    [ "$output" != "$p1" ]
}

@test "runtime inputs do not move the key: they reuse the same guest" {
    base="$(key --base)"
    run env MVM_MEM=8192 MVM_CPU=4 MVM_CPU_MODEL=Nehalem MVM_NAT='tcp:8080:80' MVM_SYNC=scp bash "$REPO/scripts/key.sh" --base
    [ "$output" = "$base" ]
}

@test "the prepared key differs from the layer, and moves with prepare and the suffix" {
    base="$(key --layer)"
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

# spec: packer-plugin-macosx docs/decisions/0009, "The instruction-set levels" -- a guest prepared
#       on one CPU is not the guest another level would have prepared (a build in prepare may probe
#       the CPU), so a matrix over cpu-isa with cache-after-prepare keeps one prepared guest per CPU
@test "the prepared key moves with the guest CPU" {
    MVM_PREPARE='echo one' MVM_CPU_MODEL='Penryn,vendor=GenuineIntel' run key --prepared
    p1="$output"
    MVM_PREPARE='echo one' MVM_CPU_MODEL='SandyBridge,vendor=GenuineIntel' run key --prepared
    [ "$status" -eq 0 ]
    [ "$output" != "$p1" ] || { echo "the prepared key ignores the cpu model"; false; }
}

@test "a missing or empty pin is an error, not a key" {
    : > "$ROOT/components/packer-plugin-macosx/version"
    run key --base
    [ "$status" -ne 0 ]
    [[ "$output" == *"packer-plugin-macosx"* ]] || false
}

@test "the repo's own box.pkrvars.hcl, guest recipe, layer recipe and pin exist and produce keys" {
    MVM_ROOT="$REPO" run key --base
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9a-f]{64}$ ]] || false
    MVM_ROOT="$REPO" run key --layer
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [[ "$output" =~ ^[0-9a-f]{64}$ ]] || false
}
