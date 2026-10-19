#!/usr/bin/env bats
#
# Debug output, cleanup and secrecy: the key never in a log, the decrypted guest gone
# from disk when the step ends, the guest's logs on failure, and pinned tools only.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export PATH="$REPO/tests/stubs:$PATH" STUB_LOG="$BATS_TEST_TMPDIR/stub.log" STUB_SSH_UP=1
    : > "$STUB_LOG"
    export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME/.ssh"; : > "$HOME/.ssh/config"
    S="$BATS_TEST_TMPDIR/scripts"; mkdir -p "$S"; cp "$REPO/scripts/main.sh" "$S/"
    export CALLS="$BATS_TEST_TMPDIR/calls"; : > "$CALLS"
    for f in key.sh image.sh build.sh layer.sh boot.sh sync.sh run.sh shell-wrapper.sh space.sh snapshot.sh; do
        cat > "$S/$f" <<STUB
#!/bin/bash
printf '%s %s\n' "$f" "\$*" >> "\$CALLS"
case "$f \$1" in
  "key.sh "*) echo kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk ;;
  # every image pulled is bound to the one under it: one id serves as image-id and backing-id
  "image.sh pull") mkdir -p "\$3" && printf decrypted > "\$3/box_0.img" \
                     && for i in image-id backing-id; do echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa > "\$3/\$i"; done ;;
  "run.sh "*) grep -q fail "\$1" && exit 7; exit 0 ;;
esac
exit 0
STUB
        chmod +x "$S/$f"
    done
    export MVM_DATA_DIR="$BATS_TEST_TMPDIR/data" GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out"
    export MVM_DISABLE_CACHE=false MVM_CACHE_AFTER_PREPARE=false MVM_SYNC_TIME=false MVM_DEBUG_ON_ERROR=false
    export MVM_PREPARE= MVM_RUN='echo run' MVM_IMAGE_KEY='AGE-SECRET-KEY-1NEVERINALOG'
}

# spec: a prepared hit pulls all three images: the prepared, its layer and their base
@test "when the step ends, the decrypted guest is gone from disk: base, layer and prepared" {
    MVM_CACHE_AFTER_PREPARE=true MVM_PREPARE='echo prep' run bash "$S/main.sh"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    grep -q "^image.sh pull .* $MVM_DATA_DIR/prepared$" "$CALLS"
    for d in box layer prepared; do [ -d "$MVM_DATA_DIR/$d" ] && [ ! -e "$MVM_DATA_DIR/$d/box_0.img" ] || { echo "left: $d"; false; }; done
}

@test "even a failing run removes the decrypted guest" {
    MVM_RUN='fail' run bash "$S/main.sh"
    [ "$status" -eq 7 ]
    for d in box layer; do [ -d "$MVM_DATA_DIR/$d" ] && [ ! -e "$MVM_DATA_DIR/$d/box_0.img" ] || { echo "left: $d"; false; }; done
}

# spec: a cancelled job's SIGKILL skips layer.sh's own cleanup, and a killed build.sh leaves its work
#       dir; the decrypted full layer guest and packer's output go when the step ends all the same
@test "when the step ends, a layer build's leftovers are gone: layer-full and build" {
    cat > "$S/layer.sh" <<'X'
#!/bin/bash
printf 'layer.sh %s\n' "$*" >> "$CALLS"
mkdir -p "$MVM_DATA_DIR/layer-full" "$MVM_DATA_DIR/build/output" "$2"
printf decrypted > "$MVM_DATA_DIR/layer-full/box_0.img"
printf decrypted > "$MVM_DATA_DIR/build/output/mavericks.box"
exit "$LAYER_RC"
X
    for rc in 0 1; do
        mkdir -p "$MVM_DATA_DIR/box"  # the stub build.sh makes no box dir
        LAYER_RC=$rc MVM_DISABLE_CACHE=true run bash "$S/main.sh"
        [ "$status" -eq "$rc" ] || { echo "layer.sh exit $rc: main.sh exit $status: $output"; false; }
        grep -q '^layer.sh ' "$CALLS"
        for d in layer-full build; do
            [ ! -e "$MVM_DATA_DIR/$d" ] || { echo "layer.sh exit $rc: left $d"; false; }
        done
    done
}

@test "debug-on-error prints the guest's system log when run fails" {
    MVM_RUN='fail' MVM_DEBUG_ON_ERROR=true run bash "$S/main.sh"
    [ "$status" -eq 7 ]
    grep -q 'mavericks .*system.log' "$STUB_LOG"
}

@test "without debug-on-error, a failure asks the guest for nothing more" {
    MVM_RUN='fail' run bash "$S/main.sh"
    run grep -q 'system.log' "$STUB_LOG"
    [ "$status" -ne 0 ]
}

@test "the key is masked, and printed nowhere else" {
    run bash "$S/main.sh"
    [[ "$output" == *"::add-mask::$MVM_IMAGE_KEY"* ]] || false
    rest="${output//::add-mask::$MVM_IMAGE_KEY/}"
    [[ "$rest" != *"$MVM_IMAGE_KEY"* ]] || false
}

@test "no script turns on xtrace" {
    run grep -lE 'set -[a-z]*x|xtrace' "$REPO"/scripts/*.sh
    [ "$status" -ne 0 ] || { echo "xtrace in: $output"; false; }
}

@test "action.yml hands image-key to the run step only, never the input check" {
    run python3 - "$REPO/action.yml" <<'PY'
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["runs"]["steps"]
holders = [s.get("name") for s in steps if "inputs.image-key" in str(s.get("env", {}).values()) and "!= ''" not in str(s.get("env", {}))]
print(holders)
sys.exit(0 if holders == ["Run in Mavericks"] else 1)
PY
    [ "$status" -eq 0 ] || { echo "$output"; false; }
}

# A runner of the test's own, ahead of the stubs on PATH, so that nothing reaches the real system:
# a sudo that only logs and runs nothing, uname -r printing FAKE_RELEASE, and apt-cache knowing
# FAKE_APT_HAS's packages. None of them writes anything but the log, in this test's tmp dir.
# FAKE_STALL_UPDATE hangs apt-get update every time, and FAKE_STALL_INSTALL_ONCE the first
# apt-get install, as a stalled mirror would.
fake_runner() {
    fake="$BATS_TEST_TMPDIR/fake"; mkdir -p "$fake"
    export PATH="$fake:$PATH" FAKE_LOG="$BATS_TEST_TMPDIR/sudo.log" MVM_MODULES_DIR="$BATS_TEST_TMPDIR/modules"
    export MVM_TOOLS_DIR="$BATS_TEST_TMPDIR/tools" STUB_TEMPLATE_ZIP="$BATS_TEST_TMPDIR/bad.tgz"
    export GITHUB_ENV="$BATS_TEST_TMPDIR/github-env"
    printf 'not the release' > "$STUB_TEMPLATE_ZIP"
    : > "$FAKE_LOG"; : > "$GITHUB_ENV"
    cat > "$fake/sudo" <<'X'
#!/bin/bash
printf 'sudo %s\n' "$*" >> "$FAKE_LOG"
case "$*" in
  *apt-get*" update"*)
    [ -z "${FAKE_STALL_UPDATE:-}" ] || { echo "Ign:1 http://azure.archive.ubuntu.com"; sleep 30; } ;;
  *apt-get*" install "*)
    [ -z "${FAKE_STALL_INSTALL_ONCE:-}" ] || [ -e "$FAKE_LOG.stalled" ] || { : > "$FAKE_LOG.stalled"; sleep 30; } ;;
esac
exit 0
X
    cat > "$fake/uname" <<'X'
#!/bin/sh
[ "$*" = -r ] || { echo "fake uname: only -r" >&2; exit 1; }
echo "$FAKE_RELEASE"
X
    cat > "$fake/apt-cache" <<'X'
#!/bin/bash
[ "$1" = show ] || { echo "fake apt-cache: not $1" >&2; exit 1; }
for p in ${FAKE_APT_HAS:-}; do [ "$p" != "$2" ] || { echo "Package: $p"; exit 0; }; done
echo "E: No packages found" >&2; exit 100
X
    chmod +x "$fake/sudo" "$fake/uname" "$fake/apt-cache"
}

# kernel_tree <release> module|builtin|none: the release's module tree, Ubuntu's Azure layout, with
# hfsplus a module, built in, or neither (6.17's without linux-modules-extra)
kernel_tree() {
    local d="$MVM_MODULES_DIR/$1"
    mkdir -p "$d/kernel/fs/nls"
    : > "$d/kernel/fs/nls/nls_utf8.ko.zst"
    printf 'kernel/fs/nls/nls_base.ko\nkernel/drivers/virtio/virtio_blk.ko\n' > "$d/modules.builtin"
    case "$2" in
      module) mkdir -p "$d/kernel/fs/hfsplus"; : > "$d/kernel/fs/hfsplus/hfsplus.ko.zst" ;;
      builtin) echo kernel/fs/hfsplus/hfsplus.ko >> "$d/modules.builtin" ;;
    esac
}

@test "install-tools installs what the plugin builds with, and lets the plugin read the running kernel" {
    fake_runner
    export FAKE_RELEASE=7.0.0-1017-azure; kernel_tree "$FAKE_RELEASE" module
    run bash "$REPO/scripts/install-tools.sh"
    install="$(grep '^sudo apt-get .* install ' "$FAKE_LOG" | tr '\n' ' ')"
    for pkg in nasm acpica-tools uuid-dev dmg2img hfsprogs busybox-static; do
        [[ " $install " == *" $pkg "* ]] || { echo "not installed: $pkg"; false; }
    done
    grep -qxF "sudo chmod 644 /boot/vmlinuz-7.0.0-1017-azure" "$FAKE_LOG"
    grep -qxF "sudo tee /sys/module/kvm/parameters/ignore_msrs" "$FAKE_LOG"
}

# spec: the plugin's microVM boots a kernel of the runner's and loads hfsplus into it. Ubuntu's
#       Azure kernels through 6.17 keep hfsplus in linux-modules-extra-<release>; 7.0's have no such
#       package, and hfsplus is in linux-modules-<release>, which every kernel has (runner image
#       ubuntu24/20261018.339 asked for linux-modules-extra-7.0.0-1017-azure, which does not exist:
#       Mavergreen/longboat Actions run 39311778407). What is installed follows from what the
#       running kernel lacks, never from a package name alone.
@test "install-tools: a running kernel with hfsplus, a module or built in, gets no kernel package" {
    fake_runner
    for how in module builtin; do
        export FAKE_RELEASE="7.0.0-1017-$how"; kernel_tree "$FAKE_RELEASE" "$how"; : > "$FAKE_LOG"; : > "$STUB_LOG"
        run bash "$REPO/scripts/install-tools.sh"
        ! grep -E 'linux-(modules|image)|dpkg-deb|depmod' "$FAKE_LOG" || { echo "$how: a kernel package"; false; }
        grep -q '^curl ' "$STUB_LOG" || { echo "$how: stopped before the downloads: $output"; false; }
        [[ "$output" == *"install-tools: the running kernel, $FAKE_RELEASE, has hfsplus: no kernel package to install"* ]] \
            || { echo "$how: $output"; false; }
    done
}

@test "install-tools: a running kernel without hfsplus gets its linux-modules-extra, when the archive has it" {
    fake_runner
    export FAKE_RELEASE=6.17.0-1022-azure FAKE_APT_HAS=linux-modules-extra-6.17.0-1022-azure
    kernel_tree "$FAKE_RELEASE" none
    run bash "$REPO/scripts/install-tools.sh"
    grep -q '^sudo apt-get .* install .*linux-modules-extra-6.17.0-1022-azure$' "$FAKE_LOG" || { cat "$FAKE_LOG"; false; }
    ! grep -E ' download |dpkg-deb' "$FAKE_LOG" || false
    [[ "$output" == *"the running kernel, 6.17.0-1022-azure, has no hfsplus; installing linux-modules-extra-6.17.0-1022-azure, which has it, before this run knows whether it builds the base image"* ]] || false
}

# spec: Ubuntu's Azure kernels through 6.17 keep hfsplus in linux-modules-extra-<release>, and a
#       runner whose kernel lacks it, with no -extra in the archive, could only get it by booting
#       another kernel, which the pinned plugin never does (packer-plugin-macosx's privops
#       chooseRelease comes in a later release). So the step names it and lets the run go on: a
#       run that never builds the base image never needs it, and main.sh stops one that does.
@test "install-tools: a running kernel without hfsplus that the archive cannot make up for is named, and the run goes on" {
    fake_runner
    export FAKE_RELEASE=6.17.0-1022-azure
    kernel_tree "$FAKE_RELEASE" none
    run bash "$REPO/scripts/install-tools.sh"
    [[ "$output" == *"::warning title=mavericks-vm::the running kernel, 6.17.0-1022-azure, has no hfsplus module, and the archive has no linux-modules-extra-6.17.0-1022-azure: building the base image here would fail, so this run stops if it must build one"* ]] || { echo "$output"; false; }
    grep -qxF "MVM_NO_HFSPLUS=6.17.0-1022-azure" "$GITHUB_ENV" || { cat "$GITHUB_ENV"; false; }
    ! grep -E 'linux-(modules|image)|dpkg-deb|depmod' "$FAKE_LOG" || false
    grep -q '^curl ' "$STUB_LOG" || { echo "stopped before the downloads: $output"; false; }
}

@test "install-tools: a running kernel with hfsplus leaves the run free to build the base image" {
    fake_runner
    for how in module builtin; do
        export FAKE_RELEASE="7.0.0-1017-$how"; kernel_tree "$FAKE_RELEASE" "$how"; : > "$GITHUB_ENV"
        run bash "$REPO/scripts/install-tools.sh"
        ! grep -q MVM_NO_HFSPLUS "$GITHUB_ENV" || { echo "$how: $(cat "$GITHUB_ENV")"; false; }
    done
    export FAKE_RELEASE=6.17.0-1022-azure FAKE_APT_HAS=linux-modules-extra-6.17.0-1022-azure; kernel_tree "$FAKE_RELEASE" none
    run bash "$REPO/scripts/install-tools.sh"
    ! grep -q MVM_NO_HFSPLUS "$GITHUB_ENV" || { echo "extra: $(cat "$GITHUB_ENV")"; false; }
}

@test "install-tools pins age, oras and packer by sha256, and refuses other bytes" {
    for t in age oras packer; do grep -qE "^${t}_sha256=[0-9a-f]{64}$" "$REPO/scripts/install-tools.sh" || { echo "no pin for $t"; false; }; done
    printf 'not the release' > "$BATS_TEST_TMPDIR/bad.tgz"
    STUB_TEMPLATE_ZIP="$BATS_TEST_TMPDIR/bad.tgz" MVM_TOOLS_DIR="$BATS_TEST_TMPDIR/tools" MVM_SKIP_APT=1 \
        run bash "$REPO/scripts/install-tools.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"sha256"* ]] || false
}

@test "action.yml: the repo cache is restored after the input check and before the run, and saved after it" {
    run python3 - "$REPO/action.yml" <<'PY'
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["runs"]["steps"]
names = [s.get("name") for s in steps]
uses = [s.get("uses", "") for s in steps]
rs = [i for i, u in enumerate(uses) if u.startswith("actions/cache/restore@")]
ws = [i for i, u in enumerate(uses) if u.startswith("actions/cache/save@")]
check = names.index("Check the inputs"); main = names.index("Run in Mavericks")
ok = len(rs) == 3 and len(ws) == 3
r, w = rs[0], ws[0]
ok = ok and all(check < i < main for i in rs) and all(main < i for i in ws)
for i, out in zip(ws, ("cache-save-base", "cache-save-layer", "cache-save-prepared")):
    save_if = steps[i].get("if", "")
    ok = ok and "always()" in save_if and out in save_if
key_if = next(s for s in steps if s.get("id") == "key").get("if", "")
ok = ok and all(steps[i].get("if", "").startswith(key_if) for i in rs) and "env.MVM_STORE == 'file'" in key_if
# spec: tests/image.bats -- a guest that will not decrypt (the key changed) is rebuilt and saved
#       under a newer name; restore takes the newest by prefix, never an exact name
rw, ww = steps[r].get("with", {}), steps[w].get("with", {})
# (tests/main.bats holds the full key and path table)
ok = ok and rw.get("restore-keys", "").strip().endswith("${{ steps.key.outputs.base }}-")
ok = ok and ww.get("key", "").endswith("-${{ github.run_id }}-${{ github.run_attempt }}")
print(names, [steps[i].get("if") for i in ws])
sys.exit(0 if ok else 1)
PY
    [ "$status" -eq 0 ] || { echo "$output"; false; }
}

# spec: install-tools sent apt's output to /dev/null and gave apt and curl no time limit, so a
#       stalled mirror or connection hung a job for 79 minutes without a word (Mavergreen/openssh
#       Actions run 37672419741); each step now says what it is, and one that stalls is cut off,
#       named, with what it printed
@test "install-tools: an apt step that stalls every time is cut off, tried again, and named" {
    fake_runner
    export FAKE_RELEASE=7.0.0-1017-azure FAKE_STALL_UPDATE=1; kernel_tree "$FAKE_RELEASE" module
    start=$SECONDS
    MVM_APT_TIMEOUT=2 MVM_APT_TRIES=2 run bash "$REPO/scripts/install-tools.sh"
    [ "$status" -ne 0 ]
    [ $((SECONDS - start)) -le 12 ] || { echo "took $((SECONDS - start))s"; false; }
    [ "$(grep -c 'apt-get .*update' "$FAKE_LOG")" -eq 2 ] || { cat "$FAKE_LOG"; false; }
    [[ "$output" == *"apt-get update did not finish in 2s, 2 times"* ]] || false
    [[ "$output" == *"Ign:1 http://azure.archive.ubuntu.com"* ]] || false
}

# spec: apt's install of linux-modules-extra took 12-22 s on GitHub's runners, and on 2026-10-08
#       twice printed nothing for the whole 600 s (runs 37833815882 and 37836734837), each
#       costing a rerun of the job; a stalled apt install is cut off sooner and tried again, after
#       dpkg finishes whatever the killed attempt left half done
@test "install-tools: an apt install that stalls once is tried again, and the run goes on" {
    fake_runner
    export FAKE_RELEASE=7.0.0-1017-azure FAKE_STALL_INSTALL_ONCE=1; kernel_tree "$FAKE_RELEASE" module
    MVM_APT_TIMEOUT=2 run bash "$REPO/scripts/install-tools.sh"
    [ "$(grep -c ' install .*qemu-system-x86' "$FAKE_LOG")" -eq 2 ] || { cat "$FAKE_LOG"; false; }
    # dpkg is set straight between the two attempts
    sed -n '/ install /,$p' "$FAKE_LOG" | sed -n 2p | grep -qF 'sudo dpkg --configure -a' || { cat "$FAKE_LOG"; false; }
    [[ "$output" == *"QEMU and the plugin's build tools did not finish in 2s; trying again (2 of 3)"* ]] || false
    # and the run went on past apt
    grep -qxF "sudo tee /sys/module/kvm/parameters/ignore_msrs" "$FAKE_LOG" || { cat "$FAKE_LOG"; false; }
}

@test "install-tools: apt waits for its lock and its mirrors only so long, and curl too" {
    fake_runner
    # the longest path through apt: the running kernel's linux-modules-extra
    export FAKE_RELEASE=6.17.0-1022-azure FAKE_APT_HAS=linux-modules-extra-6.17.0-1022-azure
    kernel_tree "$FAKE_RELEASE" none
    run bash "$REPO/scripts/install-tools.sh"
    [ "$(grep -c '^sudo apt-get' "$FAKE_LOG")" -eq 3 ] || { cat "$FAKE_LOG"; false; }
    while read -r line; do
        [[ "$line" == *"-o DPkg::Lock::Timeout="* && "$line" == *"-o Acquire::http::Timeout="* ]] \
            || { echo "unbounded: $line"; false; }
    done < <(grep '^sudo apt-get' "$FAKE_LOG")
    grep -q '^curl-args .*--connect-timeout [0-9]* .*--max-time [0-9]*' "$STUB_LOG"
}
