#!/usr/bin/env bats
#
# The runner's data and cache directories: made before anything writes there, and
# owned by the runner's user, even where the parent (/mnt on GitHub's images) is root's.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    # A sudo of this test's own that only logs: nothing here may reach the real one.
    FAKE="$BATS_TEST_TMPDIR/fake"; mkdir -p "$FAKE"
    printf '#!/bin/sh\nprintf "sudo %%s\\n" "$*" >> "%s/sudo.log"\n' "$BATS_TEST_TMPDIR" > "$FAKE/sudo"
    chmod +x "$FAKE/sudo"
    export PATH="$FAKE:$PATH"
}

dirs() { bash "$REPO/scripts/dirs.sh"; }

@test "directories the runner's user can make are made without sudo" {
    export MVM_DATA_DIR="$BATS_TEST_TMPDIR/data" MVM_CACHE_DIR="$BATS_TEST_TMPDIR/data/cache"
    run dirs
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ -d "$MVM_DATA_DIR" ]; [ -d "$MVM_CACHE_DIR" ]
    [ ! -e "$BATS_TEST_TMPDIR/sudo.log" ]
}

@test "under a parent the runner's user cannot write, sudo makes them and gives them to that user" {
    locked="$BATS_TEST_TMPDIR/locked"; mkdir -p "$locked"; chmod 555 "$locked"
    export MVM_DATA_DIR="$locked/mavericks-vm" MVM_CACHE_DIR="$locked/mavericks-vm/cache"
    run dirs
    chmod 755 "$locked"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    grep -qxF "sudo mkdir -p $MVM_DATA_DIR $MVM_CACHE_DIR" "$BATS_TEST_TMPDIR/sudo.log"
    grep -qxF "sudo chown $(id -u):$(id -g) $MVM_DATA_DIR $MVM_CACHE_DIR" "$BATS_TEST_TMPDIR/sudo.log"
}

@test "action.yml makes the directories after the input check and before the cache restore" {
    run python3 - "$REPO/action.yml" <<'PY'
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["runs"]["steps"]
names = [s.get("name") for s in steps]
uses = [s.get("uses", "") for s in steps]
d = next(i for i, s in enumerate(steps) if "scripts/dirs.sh" in s.get("run", ""))
r = next(i for i, u in enumerate(uses) if u.startswith("actions/cache/restore@"))
sys.exit(0 if names.index("Check the inputs") < d < r else 1)
PY
    [ "$status" -eq 0 ] || { echo "$output"; false; }
}
