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
    export STUB_TEMPLATE_ZIP="$BATS_TEST_TMPDIR/template.zip" STUB_TEMPLATE_SEEN="$BATS_TEST_TMPDIR/template-seen.hcl"
    PIN="$(tr -d '[:space:]' < "$REPO/components/packer-plugin-macosx/version")"
}

build() { bash "$REPO/scripts/build.sh" mavericks "$@"; }
build_layer() { bash "$REPO/scripts/build.sh" mavericks-aquatransport "$@"; }

@test "the template comes from the pinned release, by its exact asset name" {
    run build "$BATS_TEST_TMPDIR/out"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    grep -qxF "curl https://github.com/Mavergreen/packer-plugin-macosx/releases/download/$PIN/packer-plugin-macosx_${PIN}_mavericks_template.zip" "$STUB_LOG"
}

# spec: every failure is bounded in time: a download that stalls fails instead of holding the job
@test "the template download is bounded in time" {
    run build "$BATS_TEST_TMPDIR/out"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    grep -q '^curl-args -fsSL --retry 3 --connect-timeout 20 --max-time 120 .*_mavericks_template.zip$' "$STUB_LOG" \
        || { cat "$STUB_LOG"; false; }
}

@test "a failed template download exits 1 saying which download failed" {
    STUB_TEMPLATE_ZIP="$BATS_TEST_TMPDIR/absent.zip" run build "$BATS_TEST_TMPDIR/out"
    [ "$status" -eq 1 ]
    [[ "$output" == *"build.sh: downloading packer-plugin-macosx_${PIN}_mavericks_template.zip failed"* ]] || { echo "$output"; false; }
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

# spec: tests/guest_logs.bats -- Actions run 41250564922 failed a base build at "Error uploading
#       script: Process exited with status 1" with nothing to say why: packer printed no times,
#       its debug log (scp's stderr) was not written, and packer deleted the disk and the serial
#       console went with the job. A failed build now keeps them, under MVM_LOG_DIR/<template>.
@test "packer builds with a debug log and -on-error=abort, so a failure's timeline and disk survive it" {
    run build "$BATS_TEST_TMPDIR/out"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    grep -q '^packer build -on-error=abort ' "$STUB_LOG" || { cat "$STUB_LOG"; false; }
    grep -qxF "packer-debug PACKER_LOG=1 PACKER_LOG_PATH=$MVM_DATA_DIR/build/packer-debug.log" "$STUB_LOG" \
        || { cat "$STUB_LOG"; false; }
}

@test "a failed build keeps packer's output and debug log and the serial console, under the log dir" {
    export MVM_LOG_DIR="$BATS_TEST_TMPDIR/logs"
    STUB_PACKER_FAIL=1 run build "$BATS_TEST_TMPDIR/out"
    [ "$status" -eq 1 ]
    grep -q 'the host check refused' "$MVM_LOG_DIR/mavericks/packer-build.log"
    grep -q 'Started Qemu' "$MVM_LOG_DIR/mavericks/packer-debug.log"
    grep -q 'serial from the stub' "$MVM_LOG_DIR/mavericks/serial-output-mavericks-install.log"
    [ -f "$MVM_LOG_DIR/mavericks/summary.txt" ]
    [[ "$output" == *"kept in $MVM_LOG_DIR/mavericks"* ]] || { echo "$output"; false; }
    run find "$MVM_LOG_DIR" -name '*.qcow2' -o -name '*.img' -o -name '*.box'
    [ -z "$output" ] || { echo "kept: $output"; false; }
}

@test "the layer's failed build keeps its logs under its own name" {
    export MVM_LOG_DIR="$BATS_TEST_TMPDIR/logs"
    mkdir -p "$BATS_TEST_TMPDIR/base"
    STUB_PACKER_FAIL=1 run build_layer "$BATS_TEST_TMPDIR/out" "$BATS_TEST_TMPDIR/base"
    [ "$status" -eq 1 ]
    grep -q 'the host check refused' "$MVM_LOG_DIR/mavericks-aquatransport/packer-build.log"
}

@test "a good build keeps no logs, and a failed one with no log dir fails as before" {
    export MVM_LOG_DIR="$BATS_TEST_TMPDIR/logs"
    run build "$BATS_TEST_TMPDIR/out"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ ! -e "$MVM_LOG_DIR" ]
    unset MVM_LOG_DIR
    STUB_PACKER_FAIL=1 run build "$BATS_TEST_TMPDIR/out"
    [ "$status" -eq 1 ]
    [[ "$output" == *"the host check refused"* ]] || false
}

# spec: what packer writes reaches a job artifact, so the image key and the job's token never
#       enter its environment
@test "packer build never sees the image key or the job's token" {
    MVM_IMAGE_KEY=AGE-SECRET-KEY-1BUILDTEST MVM_TOKEN=ghp_buildtoken run build "$BATS_TEST_TMPDIR/out"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    grep -qxF 'packer-secrets build none' "$STUB_LOG" || { cat "$STUB_LOG"; false; }
}

# spec: the QMP hunt (packer-plugin-macosx, branch ssh-window): the hunt branch builds on the pinned
#       release's template, plus the one row the plugin's branch adds, a QMP socket beside the output
#       directory, so a stalled QEMU can be asked what it thinks before it is stopped
@test "hunt: with MVM_HUNT_QMP the template gets the plugin branch's QMP row after -uuid, and only that" {
    printf 'source "qemu" "mavericks" {\n  qemuargs = [\n    ["-uuid", local.build_uuid],\n    ["-drive", "x"],\n  ]\n}\n' \
        > "$BATS_TEST_TMPDIR/z/templates/mavericks/mavericks.pkr.hcl"
    (cd "$BATS_TEST_TMPDIR/z" && rm -f ../template.zip && zip -qr ../template.zip templates)
    cp "$BATS_TEST_TMPDIR/z/templates/mavericks/mavericks.pkr.hcl" "$BATS_TEST_TMPDIR/orig.hcl"
    MVM_HUNT_QMP=1 run build "$BATS_TEST_TMPDIR/out"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    cat > "$BATS_TEST_TMPDIR/want.hcl" <<'HCL'
source "qemu" "mavericks" {
  qemuargs = [
    ["-uuid", local.build_uuid],
    ["-qmp", "unix:${local.output_directory}-qmp.sock,server,nowait"],
    ["-drive", "x"],
  ]
}
HCL
    # the template packer was given
    grep -q '^packer build ' "$STUB_LOG"
    cmp "$BATS_TEST_TMPDIR/want.hcl" "$STUB_TEMPLATE_SEEN" || { diff "$BATS_TEST_TMPDIR/want.hcl" "$STUB_TEMPLATE_SEEN"; false; }
}

@test "hunt: without MVM_HUNT_QMP the template is exactly the release's" {
    printf 'source "qemu" "mavericks" {\n  qemuargs = [\n    ["-uuid", local.build_uuid],\n  ]\n}\n' \
        > "$BATS_TEST_TMPDIR/z/templates/mavericks/mavericks.pkr.hcl"
    (cd "$BATS_TEST_TMPDIR/z" && rm -f ../template.zip && zip -qr ../template.zip templates)
    cp "$BATS_TEST_TMPDIR/z/templates/mavericks/mavericks.pkr.hcl" "$BATS_TEST_TMPDIR/orig.hcl"
    run build "$BATS_TEST_TMPDIR/out"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    cmp "$BATS_TEST_TMPDIR/orig.hcl" "$STUB_TEMPLATE_SEEN"
}

@test "hunt: a template without the -uuid row to anchor on fails the step, never a hunt without QMP" {
    MVM_HUNT_QMP=1 run build "$BATS_TEST_TMPDIR/out"
    [ "$status" -eq 1 ]
    [[ "$output" == *"MVM_HUNT_QMP"*"-uuid"* ]] || { echo "$output"; false; }
}

@test "hunt: the layer's template is left alone" {
    mkdir -p "$BATS_TEST_TMPDIR/base"
    MVM_HUNT_QMP=1 run build_layer "$BATS_TEST_TMPDIR/out" "$BATS_TEST_TMPDIR/base"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
}
