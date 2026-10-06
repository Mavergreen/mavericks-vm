#!/usr/bin/env bats
#
# v1.0.<commit count>, shipyard's shape: the line from UPSTREAM_VERSION, N from history.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    DIR="$BATS_TEST_TMPDIR/vt"; mkdir -p "$DIR/build"
    cp "$REPO/build/version.sh" "$DIR/build/"
    printf '1.0\n' > "$DIR/UPSTREAM_VERSION"
    git -C "$DIR" init -q; git -C "$DIR" config user.email t@example.invalid; git -C "$DIR" config user.name t
    git -C "$DIR" add -A; git -C "$DIR" -c commit.gpgsign=false commit -qm one
    git -C "$DIR" -c commit.gpgsign=false commit -qm two --allow-empty
}

@test "the version is the line and the commit count, and the tag is v and that" {
    run sh "$DIR/build/version.sh"
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'FULL=1.0.2\nTAG=v1.0.2')" ]
}

@test "a full version in UPSTREAM_VERSION is refused: it holds the line" {
    printf '1.0.3\n' > "$DIR/UPSTREAM_VERSION"
    run sh "$DIR/build/version.sh"
    [ "$status" -ne 0 ]
}

@test "a shallow clone is refused: its commit count means nothing" {
    git clone -q --depth 1 "file://$DIR" "$BATS_TEST_TMPDIR/shallow"
    run sh "$BATS_TEST_TMPDIR/shallow/build/version.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *shallow* ]] || false
}
