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
    for f in key.sh image.sh build.sh boot.sh sync.sh run.sh shell-wrapper.sh space.sh snapshot.sh; do
        cat > "$S/$f" <<STUB
#!/bin/bash
printf '%s %s\n' "$f" "\$*" >> "\$CALLS"
case "$f \$1" in
  "key.sh "*) echo kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk ;;
  "image.sh pull") mkdir -p "\$3" && printf decrypted > "\$3/box_0.img" ;;
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

@test "when the step ends, the decrypted guest is gone from disk" {
    run bash "$S/main.sh"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ ! -e "$MVM_DATA_DIR/box/box_0.img" ]
}

@test "even a failing run removes the decrypted guest" {
    MVM_RUN='fail' run bash "$S/main.sh"
    [ "$status" -eq 7 ]
    [ ! -e "$MVM_DATA_DIR/box/box_0.img" ]
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

@test "install-tools installs what the plugin builds with, and lets the plugin read the running kernel" {
    # A sudo of this test's own that only logs: apt-get and chmod must never reach the real one.
    fake="$BATS_TEST_TMPDIR/fake"; mkdir -p "$fake"
    printf '#!/bin/sh\nprintf "sudo %%s\\n" "$*" >> "%s/sudo.log"\n' "$BATS_TEST_TMPDIR" > "$fake/sudo"
    chmod +x "$fake/sudo"
    printf 'not the release' > "$BATS_TEST_TMPDIR/bad.tgz"
    PATH="$fake:$PATH" STUB_TEMPLATE_ZIP="$BATS_TEST_TMPDIR/bad.tgz" MVM_TOOLS_DIR="$BATS_TEST_TMPDIR/tools" \
        run bash "$REPO/scripts/install-tools.sh"
    install="$(grep '^sudo apt-get install' "$BATS_TEST_TMPDIR/sudo.log" | tr '\n' ' ')"
    for pkg in nasm acpica-tools uuid-dev dmg2img hfsprogs busybox-static; do
        [[ " $install " == *" $pkg "* ]] || { echo "not installed: $pkg"; false; }
    done
    grep -qxF "sudo chmod 644 /boot/vmlinuz-$(uname -r)" "$BATS_TEST_TMPDIR/sudo.log"
    grep -q "^sudo apt-get install .*linux-modules-extra-$(uname -r)" "$BATS_TEST_TMPDIR/sudo.log"
    grep -qxF "sudo tee /sys/module/kvm/parameters/ignore_msrs" "$BATS_TEST_TMPDIR/sudo.log"
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
r = next(i for i, u in enumerate(uses) if u.startswith("actions/cache/restore@"))
w = next(i for i, u in enumerate(uses) if u.startswith("actions/cache/save@"))
check = names.index("Check the inputs"); main = names.index("Run in Mavericks")
ok = check < r < main < w
save_if = steps[w].get("if", "")
ok = ok and "always()" in save_if and "cache-save-key" in save_if
ok = ok and "env.MVM_STORE == 'file'" in steps[r].get("if", "")
# spec: tests/image.bats -- a guest that will not decrypt (the key changed) is rebuilt and saved
#       under a newer name; restore takes the newest by prefix, never an exact name
rw, ww = steps[r].get("with", {}), steps[w].get("with", {})
ok = ok and rw.get("restore-keys", "").strip() == "mavericks-vm-${{ steps.key.outputs.key }}-"
ok = ok and ww.get("key", "").startswith("mavericks-vm-${{ steps.main.outputs.cache-save-key }}-${{ github.run_id }}")
print(names, steps[w].get("if"))
sys.exit(0 if ok else 1)
PY
    [ "$status" -eq 0 ] || { echo "$output"; false; }
}
