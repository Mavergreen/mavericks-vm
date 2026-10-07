#!/usr/bin/env bats
#
# Running in the guest, vmactions-style: the workspace at the same path, envs passed,
# prepare then run with sh -e, the run's status, and the workspace copied back.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export PATH="$REPO/tests/stubs:$PATH" STUB_LOG="$BATS_TEST_TMPDIR/stub.log" STUB_SSH_UP=1
    : > "$STUB_LOG"
    export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME/.ssh"; : > "$HOME/.ssh/config"
    export GITHUB_WORKSPACE="$BATS_TEST_TMPDIR/work" GITHUB_PATH="$BATS_TEST_TMPDIR/github-path"
    mkdir -p "$GITHUB_WORKSPACE"; : > "$GITHUB_PATH"
    export MVM_DATA_DIR="$BATS_TEST_TMPDIR/data" MVM_SYNC=rsync MVM_COPYBACK=true MVM_ENVS= MVM_SHELL_NAME=mavericks
    SCRIPT="$BATS_TEST_TMPDIR/script.sh"
}

sync_() { bash "$REPO/scripts/sync.sh" "$@"; }
run_() { bash "$REPO/scripts/run.sh" "$@"; }

@test "rsync: the workspace goes in and comes back at the same path, over the Action's ssh config" {
    run sync_ in
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    grep -qF "rsync -a --delete -e ssh -F $HOME/.ssh/config $GITHUB_WORKSPACE/ mavericks:$GITHUB_WORKSPACE/" "$STUB_LOG"
    run sync_ out
    grep -qF "rsync -a -e ssh -F $HOME/.ssh/config mavericks:$GITHUB_WORKSPACE/ $GITHUB_WORKSPACE/" "$STUB_LOG"
}

@test "the guest gets the workspace directory, owned by vagrant, before anything is copied" {
    run sync_ in
    grep -q "^ssh -F $HOME/.ssh/config mavericks sudo mkdir -p" "$STUB_LOG"
}

@test "the guest's /home automount is switched off before the workspace path is made" {
    # 10.9 mounts auto_home on /home, where mkdir fails with "Operation not supported", and
    # GitHub's workspaces live under /home/runner/work (MEASURED 2026-10-06 on a 10.9.5 guest).
    run sync_ in
    [ "$status" -eq 0 ]
    line=$(grep -n "^ssh -F $HOME/.ssh/config mavericks .*auto_master" "$STUB_LOG" | cut -d: -f1)
    mk=$(grep -n "^ssh -F $HOME/.ssh/config mavericks .*mkdir -p" "$STUB_LOG" | cut -d: -f1)
    [ -n "$line" ] && [ -n "$mk" ] && [ "$line" -le "$mk" ]
}

@test "scp and tar carry the workspace too; no carries nothing" {
    MVM_SYNC=scp run sync_ in
    grep -qF "scp -F $HOME/.ssh/config -r -q $GITHUB_WORKSPACE/. mavericks:$GITHUB_WORKSPACE/" "$STUB_LOG"
    : > "$STUB_LOG"
    MVM_SYNC=tar run sync_ in
    grep -q "tar -C $GITHUB_WORKSPACE -xf -" "$STUB_LOG"
    : > "$STUB_LOG"
    MVM_SYNC=no run sync_ in
    run grep -E '^(rsync|scp)|tar -C' "$STUB_LOG"
    [ "$status" -ne 0 ]
}

# spec: run.sh runs in the guest at the workspace's path whatever sync is, so with sync: no that
#       path must still exist, empty: the self-test's warm job failed "cd: ... No such file or
#       directory" without it (Actions run 37551775048)
@test "no: the guest still gets the empty workspace directory, so run starts at the same path" {
    MVM_SYNC=no run sync_ in
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    grep -q "^ssh -F $HOME/.ssh/config mavericks sudo mkdir -p" "$STUB_LOG"
    grep -q "^ssh -F $HOME/.ssh/config mavericks .*auto_master" "$STUB_LOG"
}

# spec: git writes its objects read-only, and scp copies back by opening each existing file for
#       writing, so every one was refused (Actions run 37552520225); rsync and tar replace files
@test "scp copies back over read-only files, as git's objects are" {
    export STUB_GUEST_ROOT="$BATS_TEST_TMPDIR/guest"
    mkdir -p "$STUB_GUEST_ROOT$GITHUB_WORKSPACE"
    printf 'from the guest\n' > "$STUB_GUEST_ROOT$GITHUB_WORKSPACE/object"
    printf 'old\n' > "$GITHUB_WORKSPACE/object"; chmod 444 "$GITHUB_WORKSPACE/object"
    MVM_SYNC=scp run sync_ out
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$(cat "$GITHUB_WORKSPACE/object")" = 'from the guest' ]
}

@test "copyback: false copies nothing back" {
    MVM_COPYBACK=false run sync_ out
    [ "$status" -eq 0 ]
    run grep -E '^(rsync|scp)|tar -C' "$STUB_LOG"
    [ "$status" -ne 0 ]
}

@test "a script runs in the workspace with sh -e, and its status is the step's" {
    printf 'pwd > out.txt\nfalse\necho never > after.txt\n' > "$SCRIPT"
    run run_ "$SCRIPT"
    [ "$status" -ne 0 ]
    [ "$(cat "$GITHUB_WORKSPACE/out.txt")" = "$GITHUB_WORKSPACE" ]
    [ ! -e "$GITHUB_WORKSPACE/after.txt" ]
    printf 'true\n' > "$SCRIPT"
    run run_ "$SCRIPT"
    [ "$status" -eq 0 ]
}

@test "envs reach the guest with their values intact, and only those named" {
    printf 'printf "%%s|%%s|%%s" "$FOO" "$BAR" "${NOTME-unset}" > env.txt\n' > "$SCRIPT"
    FOO="a 'quoted' value" BAR='$(id)' NOTME=x MVM_ENVS='FOO BAR' run run_ "$SCRIPT"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$(cat "$GITHUB_WORKSPACE/env.txt")" = "a 'quoted' value|\$(id)|unset" ]
}

@test "an env's value never reaches a command line" {
    printf 'true\n' > "$SCRIPT"
    SECRETVAL='s3cr3t-value' MVM_ENVS='SECRETVAL' run run_ "$SCRIPT"
    run grep -F 's3cr3t-value' "$STUB_LOG"
    [ "$status" -ne 0 ]
}

@test "the custom shell is installed under its name and syncs around each step" {
    run bash "$REPO/scripts/shell-wrapper.sh" --install
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    grep -qxF "$MVM_DATA_DIR/bin" "$GITHUB_PATH"
    [ -x "$MVM_DATA_DIR/bin/mavericks" ]
    printf 'echo stepped > step.txt\n' > "$SCRIPT"
    run "$MVM_DATA_DIR/bin/mavericks" "$SCRIPT"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$(cat "$GITHUB_WORKSPACE/step.txt")" = stepped ]
    grep -q '^rsync -a --delete' "$STUB_LOG"
    grep -q '^rsync -a -e' "$STUB_LOG"
}

@test "custom-shell-name names the wrapper" {
    MVM_SHELL_NAME=mav109 run bash "$REPO/scripts/shell-wrapper.sh" --install
    [ -x "$MVM_DATA_DIR/bin/mav109" ]
}
