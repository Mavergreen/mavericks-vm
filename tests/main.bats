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
    for f in key.sh image.sh build.sh boot.sh sync.sh run.sh shell-wrapper.sh space.sh snapshot.sh; do
        cat > "$S/$f" <<STUB
#!/bin/bash
printf '%s %s\n' "$f" "\$*" >> "\$CALLS"
case "$f \$1" in
  "key.sh --prepared") echo pppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppp ;;
  "key.sh "*) echo kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk ;;
  "image.sh pull") case "\$2" in p*) exit "\${STUB_PREPARED_PULL:-3}";; *) exit "\${STUB_PULL:-0}";; esac ;;
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
order() { grep -oE '^[a-z-]+\.sh( (pull|push|in|out|hit|miss|--install|--prepared))?' "$CALLS" | paste -sd' '; }

@test "a hit: check room for a hit, pull, boot, prepare, run, copy back -- no build, no push" {
    run main
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$(order)" = "key.sh space.sh hit image.sh pull boot.sh shell-wrapper.sh --install sync.sh in run.sh run.sh sync.sh out" ]
}

@test "a miss: room for a build, build, push, then as a hit" {
    STUB_PULL=3 run main
    [ "$status" -eq 0 ]
    [ "$(order)" = "key.sh space.sh hit image.sh pull space.sh miss build.sh image.sh push boot.sh shell-wrapper.sh --install sync.sh in run.sh run.sh sync.sh out" ]
}

@test "a pull that errs (not a miss) fails the step and builds nothing" {
    STUB_PULL=1 run main
    [ "$status" -ne 0 ]
    run grep -q '^build.sh' "$CALLS"
    [ "$status" -ne 0 ]
}

@test "disable-cache builds, and neither pulls nor pushes" {
    MVM_DISABLE_CACHE=true run main
    [ "$status" -eq 0 ]
    [ "$(order)" = "key.sh space.sh miss build.sh boot.sh shell-wrapper.sh --install sync.sh in run.sh run.sh sync.sh out" ]
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

@test "cache-after-prepare, hit: the prepared guest boots, prepare is skipped, the output says so" {
    MVM_CACHE_AFTER_PREPARE=true STUB_PREPARED_PULL=0 run main
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$(order)" = "key.sh --prepared space.sh hit image.sh pull boot.sh shell-wrapper.sh --install sync.sh in run.sh sync.sh out" ]
    grep -qxF 'cache-after-prepare-hit=true' "$GITHUB_OUTPUT"
}

@test "cache-after-prepare, miss: prepare, snapshot, push the prepared key, boot it, run" {
    MVM_CACHE_AFTER_PREPARE=true run main
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$(order)" = "key.sh --prepared space.sh hit image.sh pull key.sh image.sh pull boot.sh shell-wrapper.sh --install sync.sh in run.sh snapshot.sh image.sh push boot.sh sync.sh in run.sh sync.sh out" ]
    grep -qxF 'cache-after-prepare-hit=false' "$GITHUB_OUTPUT"
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

@test "repo store, cache-after-prepare miss: only the prepared guest is cached, under its key" {
    MVM_STORE=file MVM_CACHE_AFTER_PREPARE=true STUB_PULL=3 run main
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$(grep -c '^image.sh push' "$CALLS")" = 1 ]
    grep -q '^image.sh push pppp' "$CALLS"
    grep -qxF 'cache-save-key=pppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppp' "$GITHUB_OUTPUT"
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
