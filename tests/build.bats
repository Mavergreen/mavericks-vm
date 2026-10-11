#!/usr/bin/env bats
#
# A miss builds the guest with the pinned plugin release's own Mavericks template.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export PATH="$REPO/tests/stubs:$PATH" STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
    : > "$STUB_LOG"
    export MVM_DATA_DIR="$BATS_TEST_TMPDIR/data" MVM_CACHE_DIR="$BATS_TEST_TMPDIR/data/cache"
    # A template zip shaped like the release's: templates/mavericks/...
    mkdir -p "$BATS_TEST_TMPDIR/z/templates/mavericks" "$BATS_TEST_TMPDIR/z/templates/mavericks-aquatransport"
    printf 'source "qemu" "mavericks" {}\n' > "$BATS_TEST_TMPDIR/z/templates/mavericks/mavericks.pkr.hcl"
    printf 'source "qemu" "aquatransport" {}\n' > "$BATS_TEST_TMPDIR/z/templates/mavericks-aquatransport/mavericks-aquatransport.pkr.hcl"
    (cd "$BATS_TEST_TMPDIR/z" && zip -qr ../template.zip templates)
    export STUB_TEMPLATE_ZIP="$BATS_TEST_TMPDIR/template.zip"
    PIN="$(tr -d '[:space:]' < "$REPO/components/packer-plugin-macosx/version")"
}

build() { bash "$REPO/scripts/build.sh" mavericks "$@"; }
build_layer() { bash "$REPO/scripts/build.sh" mavericks-aquatransport "$@"; }

@test "the template comes from the pinned release, by its exact asset name" {
    run build "$BATS_TEST_TMPDIR/out"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    grep -qxF "curl https://github.com/Mavergreen/packer-plugin-macosx/releases/download/$PIN/packer-plugin-macosx_${PIN}_mavericks_template.zip" "$STUB_LOG"
}

@test "the plugin is installed at exactly the pinned version, before init" {
    run build "$BATS_TEST_TMPDIR/out"
    [ "$status" -eq 0 ]
    first=$(grep -n '^packer plugins install github.com/mavergreen/macosx '"$PIN"'$' "$STUB_LOG" | cut -d: -f1)
    init=$(grep -n '^packer init' "$STUB_LOG" | cut -d: -f1)
    [ -n "$first" ] && [ -n "$init" ] && [ "$first" -lt "$init" ]
}

@test "the build is given exactly box.pkrvars.hcl, and the cache under data-dir" {
    run build "$BATS_TEST_TMPDIR/out"
    [ "$status" -eq 0 ]
    grep -q "^packer build .*-var-file=$REPO/box.pkrvars.hcl" "$STUB_LOG"
    grep -qxF "PACKER_CACHE_DIR=$MVM_CACHE_DIR" "$STUB_LOG"
}

@test "the box's contents land in the target directory" {
    run build "$BATS_TEST_TMPDIR/out"
    [ "$status" -eq 0 ]
    for f in box_0.img OVMF_CODE.fd OVMF_VARS.fd opencore.img; do
        [ -f "$BATS_TEST_TMPDIR/out/$f" ] || { echo "missing $f"; false; }
    done
}

@test "a failed build fails the step with the end of packer's output" {
    STUB_PACKER_FAIL=1 run build "$BATS_TEST_TMPDIR/out"
    [ "$status" -ne 0 ]
    [[ "$output" == *"the host check refused"* ]] || false
    [[ "$output" != *"packer line 1"$'\n'* ]] || false
}

# spec: docs/superpowers/specs/2026-10-06-mavericks-vm-design.md "Safety" (in packer-plugin-macosx)
#       -- the decrypted guest leaves the disk when the step ends; a miss left packer's own output,
#       the box and the image it was made from, under data-dir/build (final review, I5)
@test "once the box is unpacked, packer's output is gone from data-dir" {
    run build "$BATS_TEST_TMPDIR/out"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ -f "$BATS_TEST_TMPDIR/out/box_0.img" ]
    run find "$MVM_DATA_DIR/build" -name '*.box' -o -name 'box_0.img' -o -name 'output*'
    [ -z "$output" ] || { echo "left behind: $output"; false; }
}

# spec: packer reports a failed plugin install on stdout, which build.sh threw away: a repo-cache
#       job failed in 0.6 s with no word of why (Actions run 37635562340)
@test "a plugin install that fails says why, in packer's own words" {
    STUB_PACKER_INSTALL_FAIL=1 run build "$BATS_TEST_TMPDIR/out"
    [ "$status" -ne 0 ]
    [[ "$output" == *"API rate limit exceeded"* ]] || false
}

# spec: packer asks GitHub's API for a plugin unauthenticated unless given a token, and a shared
#       runner's address runs out of unauthenticated requests: install and init get the job's own
#       token; packer build, which starts QEMU, never does
@test "plugin install and init are authenticated with the job's token, and the build is not" {
    MVM_TOKEN=ghp_buildtoken run build "$BATS_TEST_TMPDIR/out"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    grep -qxF 'packer-token plugins set' "$STUB_LOG"
    grep -qxF 'packer-token init set' "$STUB_LOG"
    grep -qxF 'packer-token build ' "$STUB_LOG"
    run grep -F ghp_buildtoken "$STUB_LOG"
    [ "$status" -ne 0 ]
}

# spec: the template name picks the release asset, and the layer's template is given the base box
@test "the layer template comes from its own asset, and is given the base box" {
    mkdir -p "$BATS_TEST_TMPDIR/base"
    run build_layer "$BATS_TEST_TMPDIR/out" "$BATS_TEST_TMPDIR/base"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    grep -qxF "curl https://github.com/Mavergreen/packer-plugin-macosx/releases/download/$PIN/packer-plugin-macosx_${PIN}_mavericks-aquatransport_template.zip" "$STUB_LOG"
    grep -q "^packer build .*-var-file=$REPO/box.pkrvars.hcl .*-var base_box=$BATS_TEST_TMPDIR/base" "$STUB_LOG"
    [ -f "$BATS_TEST_TMPDIR/out/box_0.img" ]
}

@test "the base guest's build is given no base box" {
    run build "$BATS_TEST_TMPDIR/out"
    [ "$status" -eq 0 ]
    run grep -F base_box "$STUB_LOG"
    [ "$status" -ne 0 ]
}

@test "the layer template needs a base directory" {
    run build_layer "$BATS_TEST_TMPDIR/out"
    [ "$status" -eq 2 ]
    [[ "$output" == *"mavericks-aquatransport needs <base-dir>"* ]] || false
}

@test "an unknown template is refused with a usage line naming the two templates" {
    run bash "$REPO/scripts/build.sh" bogus "$BATS_TEST_TMPDIR/out"
    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown template: bogus"* ]] || false
    [[ "$output" == *"mavericks"* && "$output" == *"mavericks-aquatransport"* ]] || false
}

@test "the base guest's template takes no base directory" {
    run bash "$REPO/scripts/build.sh" mavericks "$BATS_TEST_TMPDIR/out" "$BATS_TEST_TMPDIR/base"
    [ "$status" -eq 2 ]
    [[ "$output" == *"takes no <base-dir>"* ]] || false
}

# spec: packer runs in the template dir, so a relative base would resolve against that instead
@test "a relative base directory reaches packer as an absolute path" {
    mkdir -p "$BATS_TEST_TMPDIR/rel/base"
    cd "$BATS_TEST_TMPDIR/rel"
    run build_layer "$BATS_TEST_TMPDIR/out" base
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    grep -q " -var base_box=$BATS_TEST_TMPDIR/rel/base " "$STUB_LOG"
}

# spec: one ::error per failure, naming the image: build.sh builds the base for main.sh and the
#       layer's full image for layer.sh, and each of those names what failed; build.sh's own lines
#       are plain, so a failure is never annotated twice
@test "a failed build or plugin install says why in plain lines, and leaves the ::error to its caller" {
    STUB_PACKER_FAIL=1 run build "$BATS_TEST_TMPDIR/out"
    [ "$status" -ne 0 ]
    [[ "$output" == *"the host check refused"* ]] || false
    [[ "$output" != *"::error"* ]] || false
    STUB_PACKER_INSTALL_FAIL=1 run build "$BATS_TEST_TMPDIR/out"
    [ "$status" -ne 0 ]
    [[ "$output" == *"API rate limit exceeded"* ]] || false
    [[ "$output" != *"::error"* ]] || false
}
