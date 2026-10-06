#!/usr/bin/env bats
#
# The stand-in guest is THIS machine. On 2026-10-06 a pass-through stub sudo let
# snapshot.sh's `sudo shutdown -h now` power off the developer's host, twice. These
# tests pin the stubs so that a guest-side command can never reach the real system:
# they only ever ask what a name resolves to, and ask the stub sudo to refuse.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    STUBS="$REPO/tests/stubs"
    export STUB_LOG="$BATS_TEST_TMPDIR/stub.log" STUB_SSH_UP=1
}

@test "in the stand-in guest, every dangerous name resolves to a stub" {
    for c in shutdown reboot halt poweroff systemctl date sudo; do
        run "$STUBS/ssh" -F /dev/null mavericks "command -v $c"
        [ "$output" = "$STUBS/$c" ] || { echo "$c resolves to '$output'"; false; }
    done
}

@test "the stand-in guest's PATH has no sbin" {
    run "$STUBS/ssh" -F /dev/null mavericks 'printf %s "$PATH"'
    [[ "$output" != *sbin* ]] || false
}

@test "the stub sudo refuses anything off its allowlist, by name, without running it" {
    for c in shutdown reboot date systemctl rm dd; do
        run "$STUBS/sudo" "$c" --never-run
        [ "$status" -ne 0 ]
        [[ "$output" == *"refusing '$c'"* ]] || false
    done
}
