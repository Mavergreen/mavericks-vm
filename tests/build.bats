#!/usr/bin/env bats
#
# A miss builds the guest with the pinned plugin release's own Mavericks template.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export PATH="$REPO/tests/stubs:$PATH" STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
    : > "$STUB_LOG"
    export MVM_DATA_DIR="$BATS_TEST_TMPDIR/data" MVM_CACHE_DIR="$BATS_TEST_TMPDIR/data/cache"
    # A template zip shaped like the release's: templates/mavericks/...
    mkdir -p "$BATS_TEST_TMPDIR/z/templates/mavericks"
    printf 'source "qemu" "mavericks" {}\n' > "$BATS_TEST_TMPDIR/z/templates/mavericks/mavericks.pkr.hcl"
    (cd "$BATS_TEST_TMPDIR/z" && zip -qr ../template.zip templates)
    export STUB_TEMPLATE_ZIP="$BATS_TEST_TMPDIR/template.zip"
    PIN="$(tr -d '[:space:]' < "$REPO/components/packer-plugin-macosx/version")"
}

build() { bash "$REPO/scripts/build.sh" "$@"; }

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
