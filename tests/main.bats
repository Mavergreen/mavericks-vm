#!/usr/bin/env bats
#
# The orchestration: which of pull, build, push, boot, prepare and run happen, in
# what order, on each path. The steps themselves are tested on their own; here they
# are stand-ins that record their calls.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    S="$BATS_TEST_TMPDIR/scripts"; mkdir -p "$S"
    cp "$REPO/scripts/main.sh" "$S/"
    export CALLS="$BATS_TEST_TMPDIR/calls"; : > "$CALLS"
    for f in key.sh image.sh build.sh layer.sh boot.sh sync.sh run.sh shell-wrapper.sh space.sh snapshot.sh; do
        cat > "$S/$f" <<STUB
#!/bin/bash
printf '%s %s\n' "$f" "\$*" >> "\$CALLS"
# STUB_FAIL: a glob over "<step> <args>"; a match fails the step without a word, as a step that
# fails silently would
case "$f \$*" in \${STUB_FAIL:-//}) exit 1 ;; esac
case "$f \$1" in
  "key.sh --prepared") echo pppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppp ;;
  "key.sh --layer") echo llllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllll ;;
  "key.sh "*) echo kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk ;;
  "image.sh pull")
    case "\$2" in p*) rc=\${STUB_PREPARED_PULL:-3};; l*) rc=\${STUB_LAYER_PULL:-\${STUB_PULL:-0}};; *) rc=\${STUB_PULL:-0};; esac
    [ "\$rc" -ne 0 ] || { mkdir -p "\$3" && echo pulled > "\$3/box_0.img"; }
    exit "\$rc" ;;
  # as the real layer.sh does, refuse a layer dir that is not empty
  "layer.sh "*) [ -z "\$(ls -A "\$2" 2>/dev/null)" ] || { echo "layer.sh: \$2 is not empty" >&2; exit 2; } ;;
  "run.sh "*) grep -q fail "\$1" && exit 7; exit 0 ;;
esac
exit 0
STUB
        chmod +x "$S/$f"
    done
    export PATH="$REPO/tests/stubs:$PATH" STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
    export MVM_IMAGE_KEY='AGE-SECRET-KEY-1MAINTESTKEY'
    export MVM_DATA_DIR="$BATS_TEST_TMPDIR/data" GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out"
    export MVM_DISABLE_CACHE=false MVM_CACHE_AFTER_PREPARE=false MVM_SYNC_TIME=false
    export MVM_PREPARE='echo prep' MVM_RUN='echo run'
    : > "$GITHUB_OUTPUT"
}

main() { bash "$S/main.sh"; }
order() { grep -oE '^[a-z-]+\.sh( (pull|push|in|out|hit|miss|layer|prepare|--install|--prepared|--layer|--base))?' "$CALLS" | paste -sd' '; }
called() { grep -qxF -- "$1" "$CALLS" || { echo "not called: $1"; cat "$CALLS"; false; }; }
K=kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk
L=llllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllll
P=pppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppp

@test "a layer hit: room for a hit, pull the layer and its base, boot the layer -- no build, no push" {
    run main
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$(order)" = "key.sh --layer space.sh hit image.sh pull key.sh --base image.sh pull boot.sh shell-wrapper.sh --install sync.sh in run.sh run.sh sync.sh out" ]
    D="$MVM_DATA_DIR"
    called "image.sh pull $L $D/layer"
    called "image.sh pull $K $D/box"
    called "boot.sh $D/layer"
}

@test "a layer miss with a base hit: build the layer over the pulled base, push it, boot it" {
    STUB_LAYER_PULL=3 run main
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$(order)" = "key.sh --layer space.sh hit image.sh pull key.sh --base image.sh pull space.sh layer layer.sh image.sh push boot.sh shell-wrapper.sh --install sync.sh in run.sh run.sh sync.sh out" ]
    D="$MVM_DATA_DIR"
    called "layer.sh $D/box $D/layer"
    called "image.sh push $L $D/layer"
    called "boot.sh $D/layer"
}

@test "a layer miss with a base miss: build and push the base, then the layer, boot the layer" {
    STUB_PULL=3 run main
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$(order)" = "key.sh --layer space.sh hit image.sh pull key.sh --base image.sh pull space.sh miss build.sh image.sh push space.sh layer layer.sh image.sh push boot.sh shell-wrapper.sh --install sync.sh in run.sh run.sh sync.sh out" ]
    D="$MVM_DATA_DIR"
    [ "$(grep '^image.sh push' "$CALLS" | paste -sd' ')" = "image.sh push $K $D/box image.sh push $L $D/layer" ]
    called "boot.sh $D/layer"
}

# spec: the layer is a delta over the base, so a layer whose base is gone is a broken set: it is
#       thrown away and built again over the base built here, never booted over a missing link
@test "a layer hit with a base miss: the layer is thrown away and built again over the new base" {
    STUB_LAYER_PULL=0 STUB_PULL=3 run main
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$(order)" = "key.sh --layer space.sh hit image.sh pull key.sh --base image.sh pull space.sh miss build.sh image.sh push space.sh layer layer.sh image.sh push boot.sh shell-wrapper.sh --install sync.sh in run.sh run.sh sync.sh out" ]
    D="$MVM_DATA_DIR"
    [ "$(grep '^image.sh push' "$CALLS" | paste -sd' ')" = "image.sh push $K $D/box image.sh push $L $D/layer" ]
    called "boot.sh $D/layer"
}

@test "a pull that errs (not a miss) fails the step and builds nothing" {
    STUB_PULL=1 run main
    [ "$status" -ne 0 ]
    run grep -qE '^(build|layer)\.sh' "$CALLS"
    [ "$status" -ne 0 ]
}

@test "disable-cache builds the base and the layer, boots the layer, and neither pulls nor pushes" {
    MVM_DISABLE_CACHE=true MVM_CACHE_AFTER_PREPARE=true run main
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$(order)" = "space.sh miss build.sh space.sh layer layer.sh boot.sh shell-wrapper.sh --install sync.sh in run.sh run.sh sync.sh out" ]
    called "boot.sh $MVM_DATA_DIR/layer"
}

@test "run's status is the step's, and the workspace still comes back" {
    MVM_RUN='fail now' run main
    [ "$status" -eq 7 ]
    grep -q '^sync.sh out' "$CALLS"
}

@test "a failing prepare stops the step before run" {
    MVM_PREPARE='fail now' run main
    [ "$status" -eq 7 ]
    [ "$(grep -c '^run.sh' "$CALLS")" = 1 ]
}

@test "a prepared hit: pull it, its layer and their base, boot the prepared guest, skip prepare, say so" {
    MVM_CACHE_AFTER_PREPARE=true STUB_PREPARED_PULL=0 run main
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$(order)" = "key.sh --prepared space.sh hit image.sh pull key.sh --layer image.sh pull key.sh --base image.sh pull boot.sh shell-wrapper.sh --install sync.sh in run.sh sync.sh out" ]
    D="$MVM_DATA_DIR"
    called "image.sh pull $P $D/prepared"
    called "image.sh pull $L $D/layer"
    called "image.sh pull $K $D/box"
    called "boot.sh $D/prepared"
    grep -qxF 'cache-after-prepare-hit=true' "$GITHUB_OUTPUT"
}

@test "a prepared miss with a layer hit: boot the layer, prepare, snapshot over it, push, boot the prepared" {
    MVM_CACHE_AFTER_PREPARE=true run main
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$(order)" = "key.sh --prepared space.sh hit image.sh pull key.sh --layer image.sh pull key.sh --base image.sh pull boot.sh shell-wrapper.sh --install sync.sh in run.sh space.sh prepare snapshot.sh image.sh push boot.sh sync.sh in run.sh sync.sh out" ]
    D="$MVM_DATA_DIR"
    [ "$(grep '^boot.sh' "$CALLS" | paste -sd' ')" = "boot.sh $D/layer boot.sh $D/prepared" ]
    called "snapshot.sh $D/layer $D/prepared"
    called "image.sh push $P $D/prepared"
    grep -qxF 'cache-after-prepare-hit=false' "$GITHUB_OUTPUT"
}

# spec: the prepared image is a delta over the layer: over a layer built again here it is a broken
#       chain, so it is thrown away and prepared again, never booted
@test "a prepared hit whose layer misses: the prepared is thrown away, the layer built, prepare runs again" {
    MVM_CACHE_AFTER_PREPARE=true STUB_PREPARED_PULL=0 STUB_LAYER_PULL=3 run main
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$(order)" = "key.sh --prepared space.sh hit image.sh pull key.sh --layer image.sh pull key.sh --base image.sh pull space.sh layer layer.sh image.sh push boot.sh shell-wrapper.sh --install sync.sh in run.sh space.sh prepare snapshot.sh image.sh push boot.sh sync.sh in run.sh sync.sh out" ]
    D="$MVM_DATA_DIR"
    [ "$(grep '^boot.sh' "$CALLS" | paste -sd' ')" = "boot.sh $D/layer boot.sh $D/prepared" ]
    [ "$(grep '^image.sh push' "$CALLS" | paste -sd' ')" = "image.sh push $L $D/layer image.sh push $P $D/prepared" ]
    grep -qxF 'cache-after-prepare-hit=false' "$GITHUB_OUTPUT"
}

@test "a prepared hit and a layer hit whose base misses: base, layer and prepared are all made again" {
    MVM_CACHE_AFTER_PREPARE=true STUB_PREPARED_PULL=0 STUB_LAYER_PULL=0 STUB_PULL=3 run main
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$(order)" = "key.sh --prepared space.sh hit image.sh pull key.sh --layer image.sh pull key.sh --base image.sh pull space.sh miss build.sh image.sh push space.sh layer layer.sh image.sh push boot.sh shell-wrapper.sh --install sync.sh in run.sh space.sh prepare snapshot.sh image.sh push boot.sh sync.sh in run.sh sync.sh out" ]
    D="$MVM_DATA_DIR"
    [ "$(grep '^boot.sh' "$CALLS" | paste -sd' ')" = "boot.sh $D/layer boot.sh $D/prepared" ]
    [ "$(grep '^image.sh push' "$CALLS" | paste -sd' ')" = "image.sh push $K $D/box image.sh push $L $D/layer image.sh push $P $D/prepared" ]
    grep -qxF 'cache-after-prepare-hit=false' "$GITHUB_OUTPUT"
}

# spec: every failure names the image (base, layer or prepared) and the step that failed, even
#       when the step itself fails without a word
@test "a failing step names its image and itself" {
    D="$MVM_DATA_DIR"
    while IFS='|' read -r env fail want; do
        : > "$CALLS"
        run env $env STUB_FAIL="$fail" bash "$S/main.sh"
        [ "$status" -ne 0 ] || { echo "$fail: status 0"; false; }
        [[ "$output" == *"::error title=mavericks-vm::$want failed"* ]] || { echo "$fail: $output"; false; }
    done <<'TABLE'
MVM_CACHE_AFTER_PREPARE=false|key.sh --layer|computing the layer image's key
STUB_LAYER_PULL=3|key.sh --base|computing the base image's key
MVM_CACHE_AFTER_PREPARE=true|key.sh --prepared|computing the prepared image's key
MVM_CACHE_AFTER_PREPARE=true|image.sh pull p*|pulling the prepared image
MVM_CACHE_AFTER_PREPARE=false|image.sh pull l*|pulling the layer image
MVM_CACHE_AFTER_PREPARE=false|image.sh pull k*|pulling the base image
STUB_PULL=3|build.sh *|building the base image
STUB_LAYER_PULL=3|layer.sh *|building the layer image
STUB_PULL=3|image.sh push k*|pushing the base image
STUB_LAYER_PULL=3|image.sh push l*|pushing the layer image
MVM_CACHE_AFTER_PREPARE=false|boot.sh */layer|booting the layer image
MVM_CACHE_AFTER_PREPARE=true|snapshot.sh *|snapshotting the prepared image
MVM_CACHE_AFTER_PREPARE=true|image.sh push p*|pushing the prepared image
MVM_CACHE_AFTER_PREPARE=true|boot.sh */prepared|booting the prepared image
TABLE
}

@test "with no prepare, only run runs" {
    MVM_PREPARE= run main
    [ "$(grep -c '^run.sh' "$CALLS")" = 1 ]
}

@test "repo store, miss: the step names the key it newly cached, for the save step" {
    MVM_STORE=file STUB_PULL=3 run main
    [ "$status" -eq 0 ]
    grep -qxF 'cache-save-key=kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk' "$GITHUB_OUTPUT"
}

@test "repo store, hit: nothing new to save" {
    MVM_STORE=file run main
    [ "$status" -eq 0 ]
    run grep -q '^cache-save-key=.' "$GITHUB_OUTPUT"
    [ "$status" -ne 0 ]
}

# spec: the repo tier once skipped the base's push with cache-after-prepare on, keeping only the
#       prepared guest; the prepared is now a delta over the layer, over the base, so every image
#       this run builds is pushed and named
@test "repo store, cache-after-prepare miss: base, layer and prepared are each pushed and named" {
    MVM_STORE=file MVM_CACHE_AFTER_PREPARE=true STUB_PULL=3 run main
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$(grep '^image.sh push' "$CALLS" | cut -c1-18 | paste -sd' ')" = "image.sh push kkkk image.sh push llll image.sh push pppp" ]
    for k in $K $L $P; do grep -qxF "cache-save-key=$k" "$GITHUB_OUTPUT"; done
}

@test "a failing run still reports what it cached, so it is saved anyway" {
    MVM_STORE=file STUB_PULL=3 MVM_RUN='fail' run main
    [ "$status" -eq 7 ]
    grep -q '^cache-save-key=kkkk' "$GITHUB_OUTPUT"
}

# spec: on a miss the key was first parsed after the 40-minute build, at the push; a recipient or a
#       passphrase saved as the secret fails at once instead, before anything is pulled or built
#       (final review, I4)
@test "an image-key that is not an age identity fails at once, before any pull or build" {
    MVM_IMAGE_KEY='age1thisisarecipientnotanidentity' run main
    [ "$status" -ne 0 ]
    [[ "$output" == *"image-key"* ]] || false
    [[ "$output" == *"AGE-SECRET-KEY-1"* ]] || false
    [ ! -s "$CALLS" ]
}

# spec: with cache-after-prepare on and prepare empty, the repo store kept nothing (no base push,
#       no prepared one), so every run built for 40 minutes; with no prepare the prepared guest is
#       the base guest, so it is cached as the base (final review, I3)
@test "cache-after-prepare with an empty prepare caches the base guest" {
    MVM_STORE=file MVM_CACHE_AFTER_PREPARE=true MVM_PREPARE='' STUB_PULL=3 run main
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    grep -q '^image.sh push kkkk' "$CALLS"
    grep -q '^image.sh push llll' "$CALLS"
    grep -qxF 'cache-save-key=kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk' "$GITHUB_OUTPUT"
    run grep -q 'key.sh --prepared' "$CALLS"
    [ "$status" -ne 0 ]
}

@test "action.yml's key step chooses the base key too when prepare is empty, so restore matches" {
    run python3 - "$REPO/action.yml" "$BATS_TEST_TMPDIR/keystep.sh" <<'PY'
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["runs"]["steps"]
open(sys.argv[2], "w").write(next(s for s in steps if s.get("id") == "key")["run"])
PY
    mkdir -p "$BATS_TEST_TMPDIR/action/scripts"; cp "$S/key.sh" "$BATS_TEST_TMPDIR/action/scripts/"
    : > "$GITHUB_OUTPUT"
    GITHUB_ACTION_PATH="$BATS_TEST_TMPDIR/action" MVM_BLOB_DIR=/b MVM_CACHE_AFTER_PREPARE=true MVM_PREPARE='' \
        run bash -e "$BATS_TEST_TMPDIR/keystep.sh"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    grep -qxF 'key=kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk' "$GITHUB_OUTPUT"
}

# spec: tests/build.bats -- build.sh takes the template first; a bare <dir> exits 2 and breaks the action
@test "a miss and a disabled cache both build with build.sh mavericks <box-dir>" {
    STUB_PULL=3 run main
    [ "$status" -eq 0 ]
    grep -qE '^build\.sh mavericks [^ ]+/box$' "$CALLS" || { cat "$CALLS"; false; }
    : > "$CALLS"
    MVM_DISABLE_CACHE=true run main
    [ "$status" -eq 0 ]
    grep -qE '^build\.sh mavericks [^ ]+/box$' "$CALLS" || { cat "$CALLS"; false; }
}
