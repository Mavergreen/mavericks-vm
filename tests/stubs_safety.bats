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

# spec: a fake dpkg-deb in a draft of tests/safety.bats, told by a mutated install-tools.sh to unpack
#       onto /, wrote into this machine's /boot and /lib/modules, and only a non-root permission
#       denial stopped it (packer-plugin-macosx's kskew review, 2026-10-19). Every stub that writes a file it is
#       told to refuses, by name and before writing, one outside the test's own tmp dir
#       (STUB_ROOT, or BATS_TEST_TMPDIR), and refuses all writes when it knows neither.
@test "every stub that writes a file it is told to refuses one outside the test's tmp dir" {
    export STUB_ROOT="$BATS_TEST_TMPDIR/root" STUB_REGISTRY="$BATS_TEST_TMPDIR/root/registry"
    out="$BATS_TEST_TMPDIR/outside"; mkdir -p "$STUB_ROOT" "$out" "$STUB_REGISTRY/t"
    : > "$STUB_REGISTRY/t/blob"; : > "$STUB_ROOT/in"
    export STUB_TEMPLATE_ZIP="$STUB_ROOT/in"
    refused() {  # $1 = what wrote; then the paths that must not exist
        local what="$1"; shift
        [ "$status" -ne 0 ] || { echo "$what: exit 0"; false; }
        [[ "$output" == *"refusing to write"* ]] || { echo "$what: $output"; false; }
        for p in "$@"; do [ ! -e "$p" ] || { echo "$what wrote $p"; false; }; done
    }
    run "$STUBS/curl" -o "$out/curl" https://example.invalid/x;          refused curl "$out/curl"
    run "$STUBS/age" -r age1x -o "$out/age" "$STUB_ROOT/in" < /dev/null; refused age "$out/age"
    run "$STUBS/oras" pull "r:t" -o "$out";                               refused "oras pull" "$out/box.tar.zst.age"
    STUB_REGISTRY="$out/reg" run "$STUBS/oras" push "r:u" "$STUB_ROOT/in:x"; refused "oras push" "$out/reg"
    run "$STUBS/qemu-img" create -f qcow2 "$out/img";                     refused qemu-img "$out/img"
    STUB_QEMU_ARGV="$out/argv" run "$STUBS/qemu-system-x86_64" -pidfile "$STUB_ROOT/pid"; refused qemu "$out/argv" "$STUB_ROOT/pid"
    STUB_QEMU_ARGV="$STUB_ROOT/argv" run "$STUBS/qemu-system-x86_64" -pidfile "$out/pid"; refused "qemu pidfile" "$out/pid"
    (cd "$out" && run "$STUBS/packer" build . && refused packer "$out/output" "$out/s")
    STUB_SCP_COPY=1 run "$STUBS/scp" "$STUB_ROOT/in" "$out/scp";           refused scp "$out/scp"
    run "$STUBS/sudo" mkdir -p "$out/sudo";                                refused "sudo mkdir" "$out/sudo"
    printf 'a\n' > "$out/sed"; run "$STUBS/sudo" sed -i 's/a/b/' "$out/sed"
    refused "sudo sed"; [ "$(cat "$out/sed")" = a ]
    # the stand-in guest's own scratch is admitted by its prefix, and nothing beside it
    mkdir -p "$out/g.1"
    STUB_GUEST_SCRATCH="$out/g." STUB_SCP_COPY=1 run "$STUBS/scp" "$STUB_ROOT/in" "$out/g.1/scp"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ -e "$out/g.1/scp" ] || false
    STUB_GUEST_SCRATCH="$out/g." STUB_SCP_COPY=1 run "$STUBS/scp" "$STUB_ROOT/in" "$out/h.1"; refused "scp beside the scratch" "$out/h.1"
    # and with no tmp dir to confine them to, nothing at all
    : > "$STUB_ROOT/out"
    run env -u STUB_ROOT -u BATS_TEST_TMPDIR "$STUBS/qemu-img" create "$STUB_ROOT/new"; refused "unconfined qemu-img" "$STUB_ROOT/new"
}

@test "inside the test's tmp dir, the stubs write as before" {
    export STUB_ROOT="$BATS_TEST_TMPDIR"
    run "$STUBS/qemu-img" create -f qcow2 "$BATS_TEST_TMPDIR/img"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ -e "$BATS_TEST_TMPDIR/img" ] || false
    run "$STUBS/sudo" mkdir -p "$BATS_TEST_TMPDIR/a/b"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ -d "$BATS_TEST_TMPDIR/a/b" ] || false
}

@test "the stand-in guest's commands keep the test's tmp dir, so its sudo stays confined" {
    run "$STUBS/ssh" -F /dev/null mavericks 'printf %s "$STUB_ROOT"'
    [ "$output" = "$BATS_TEST_TMPDIR" ] || { echo "STUB_ROOT in the guest: '$output'"; false; }
}
