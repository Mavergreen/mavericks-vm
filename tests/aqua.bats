#!/usr/bin/env bats
#
# aqua-session: the guest logged in to a desktop, for products whose tests need an Aqua session
# (Recaulk's NSWorkspace and context-actors tests). On 10.9 loginwindow logs in by itself only at
# boot, with the account's password in /etc/kcpassword, so the guest side gives the account a
# random password only it ever holds, writes it there, turns auto-login on, marks Setup
# Assistant's first-login screens seen, and installs guest-macosx-aqua; the host side restarts the
# guest and waits for the session. MEASURED 2026-11-07 on a 10.9.5 layer box: loginwindow's HUP
# did not log in; the reboot did, behind Setup Assistant until its screens were marked seen, then
# Dock and Finder; `launchctl asuser` from root said Background, `bsexec` into the user's
# loginwindow said Aqua, and `open -a TextEdit` launched TextEdit.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    ROOT="$BATS_TEST_TMPDIR/guest"; mkdir -p "$ROOT/private/etc" "$ROOT/Library/Preferences" "$ROOT/usr/local/bin"
    BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
    export LOG="$BATS_TEST_TMPDIR/log" DSCL_PW="$BATS_TEST_TMPDIR/dscl-pw"; : > "$LOG"
    # the guest's commands, recording; dscl keeps the password it was given, so a test can
    # compare it with kcpassword's
    cat > "$BIN/dscl" <<'EOF'
#!/bin/bash
case "$2" in
  -passwd) printf '%s' "$4" > "$DSCL_PW"; echo "dscl . -passwd $3 <password>" >> "$LOG" ;;
  -authonly) echo "dscl . -authonly $3 <password>" >> "$LOG"; [ -z "${DSCL_REJECT:-}" ] || exit 1
             [ "$4" = "$(cat "$DSCL_PW")" ] ;;
  *) exit 1 ;;
esac
EOF
    # DEFAULTS_FAIL: a glob over defaults' arguments that makes it fail
    cat > "$BIN/defaults" <<'EOF'
#!/bin/bash
echo "defaults $*" >> "$LOG"
case "$*" in ${DEFAULTS_FAIL:-//}) exit 1 ;; esac
EOF
    printf '#!/bin/bash\necho "sudo $*" >> "$LOG"\n[ "$1" = -u ] && shift 2\nexec "$@"\n' > "$BIN/sudo"
    # uids: vagrant 501; runneradmin, a name longer than ps's 8-column user field, 502
    printf '#!/bin/bash\necho "id $*" >> "$LOG"\nif [ "$2" = runneradmin ]; then echo 502; else echo 501; fi\n' > "$BIN/id"
    chmod +x "$BIN"/*
    export GUEST_AQUA_ROOT="$ROOT"
}

guest() { PATH="$BIN:$PATH" sh "$REPO/scripts/guest-aqua.sh" "${1:-vagrant}"; }
# kcpassword's format, decoded independently of the script: each byte XORed with the key,
# up to the NUL that ends the password
decode_kc() {
    python3 -c '
import sys
k = [0x7D,0x89,0x52,0x23,0xD2,0xBC,0xDD,0xEA,0xA3,0xB9,0x1F]
b = open(sys.argv[1], "rb").read()
d = bytes(c ^ k[i % 11] for i, c in enumerate(b))
assert len(b) % 12 == 0, "not a multiple of 12"
sys.stdout.write(d.split(b"\0")[0].decode())' "$1"
}

@test "the guest side: a random password, verified, in kcpassword (root's only), auto-login on" {
    run guest
    [ "$status" -eq 0 ] || { echo "$output"; cat "$LOG"; false; }
    pw="$(cat "$DSCL_PW")"
    [[ "$pw" =~ ^[A-Za-z0-9]{20}$ ]] || { echo "password: '$pw'"; false; }
    grep -qxF "dscl . -passwd /Users/vagrant <password>" "$LOG"
    grep -qxF "dscl . -authonly vagrant <password>" "$LOG"
    [ "$(decode_kc "$ROOT/private/etc/kcpassword")" = "$pw" ]
    [ "$(ls -l "$ROOT/private/etc/kcpassword" | cut -c1-10)" = -rw------- ]
    grep -qxF "defaults write $ROOT/Library/Preferences/com.apple.loginwindow autoLoginUser vagrant" "$LOG"
}

@test "the password is never printed" {
    run guest
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    pw="$(cat "$DSCL_PW")"
    [[ "$output" != *"$pw"* ]] || { echo "$output"; false; }
    ! grep -qF "$pw" "$LOG" || false
}

@test "two runs give two passwords" {
    guest > /dev/null; a="$(cat "$DSCL_PW")"
    guest > /dev/null; b="$(cat "$DSCL_PW")"
    [ "$a" != "$b" ]
}

@test "Setup Assistant's first-login screens are marked seen, as the user, before the login" {
    run guest
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    grep -qxF "sudo -u vagrant defaults write com.apple.SetupAssistant DidSeeCloudSetup -bool true" "$LOG"
    grep -qxF "sudo -u vagrant defaults write com.apple.SetupAssistant LastSeenCloudProductVersion 10.9.5" "$LOG"
}

@test "a password dscl will not verify leaves no kcpassword and no auto-login, and fails, saying why" {
    DSCL_REJECT=1 run guest
    [ "$status" -ne 0 ]
    [[ "$output" == *"dscl . -authonly did not accept"* ]] || { echo "$output"; false; }
    [ ! -e "$ROOT/private/etc/kcpassword" ]
    ! grep -q autoLoginUser "$LOG" || false
}

@test "each write the guest side cannot make fails it, naming the step, without the success line" {
    for f in '*autoLoginUser*' '*DidSeeCloudSetup*' '*LastSeenCloudProductVersion*'; do
        : > "$LOG"
        DEFAULTS_FAIL="$f" run guest
        [ "$status" -ne 0 ] || { echo "$f: $output"; false; }
        [[ "$output" == *"aqua-session: "*" failed"* ]] || { echo "$f: $output"; false; }
        [[ "$output" != *"auto-login on"* ]] || { echo "$f: $output"; false; }
    done
}

# The installed helper, run against a stand-in ps (PS_OUT: its lines, as pid uid comm) and sudo
# (MANAGER: what launchctl managername says in the bootstrap; every call is recorded)
helper_setup() {
    HB="$BATS_TEST_TMPDIR/hbin"; mkdir -p "$HB"
    printf '#!/bin/bash\ncat "$PS_OUT"\n' > "$HB/ps"
    cat > "$HB/sudo" <<'EOF'
#!/bin/bash
echo "sudo $*" >> "$LOG"
case "$*" in *"launchctl bsexec "*" launchctl managername") echo "$MANAGER" ;; esac
EOF
    chmod +x "$HB"/*
    export PS_OUT="$BATS_TEST_TMPDIR/ps" MANAGER=Aqua
}
helper() { PATH="$HB:$PATH" sh "$ROOT/usr/local/bin/guest-macosx-aqua" "$@"; }
LW=/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow
DOCK=/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock
FINDER=/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder

@test "guest-macosx-aqua runs a command in the user's loginwindow's bootstrap, as them, with its arguments" {
    guest > /dev/null; helper_setup
    printf '48 0 %s\n103 501 %s\n' "$LW" "$LW" > "$PS_OUT"
    : > "$LOG"
    run helper open -a 'Text Edit'
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    grep -qxF "sudo -E launchctl bsexec 103 sudo -E -u vagrant open -a Text Edit" "$LOG" || { cat "$LOG"; false; }
}

@test "guest-macosx-aqua --check: Aqua with Dock and Finder passes, a second Finder too; Background or no Dock does not" {
    guest > /dev/null; helper_setup
    printf '103 501 %s\n200 501 %s\n201 501 %s\n' "$LW" "$DOCK" "$FINDER" > "$PS_OUT"
    run helper --check
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    printf '202 501 %s\n' "$FINDER" >> "$PS_OUT"
    run helper --check
    [ "$status" -eq 0 ] || { echo "a second Finder: $output"; false; }
    MANAGER=Background run helper --check
    [ "$status" -ne 0 ]; [[ "$output" == Background* ]] || { echo "$output"; false; }
    printf '103 501 %s\n201 501 %s\n' "$LW" "$FINDER" > "$PS_OUT"
    run helper --check
    [ "$status" -ne 0 ] || { echo "no Dock: $output"; false; }
}

@test "guest-macosx-aqua finds the user by uid, so a name longer than ps's user column still matches" {
    guest runneradmin > /dev/null; helper_setup
    printf '103 502 %s\n200 502 %s\n201 502 %s\n' "$LW" "$DOCK" "$FINDER" > "$PS_OUT"
    run helper --check
    [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "guest-macosx-aqua says so when the user has no session, and when it is given no command" {
    guest > /dev/null; helper_setup
    printf '48 0 %s\n' "$LW" > "$PS_OUT"
    run helper --check
    [ "$status" -ne 0 ]; [[ "$output" == *"no loginwindow"* ]] || { echo "$output"; false; }
    run helper true
    [ "$status" -ne 0 ]; [[ "$output" == *"has no Aqua session"* ]] || { echo "$output"; false; }
    run helper
    [ "$status" -eq 2 ]; [[ "$output" == *"usage: guest-macosx-aqua"* ]] || { echo "$output"; false; }
}

# --- the host side ---------------------------------------------------------

# A stand-in ssh answering as a guest that restarts. The guest going down still answers with its
# old boot time OLD_ANSWERS (default 3) times; a check of it is recorded as an error. HOST_GUEST_FAIL
# fails the guest script; HOST_NEVER_AQUA keeps the check at Background; HOST_NEVER_BACK keeps the
# old boot time.
host_setup() {
    export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME/.ssh"; : > "$HOME/.ssh/config"
    export MVM_SSH_INTERVAL=0 MVM_AQUA_TIMEOUT=2 MVM_SSH_TIMEOUT=5 BOOTS="$BATS_TEST_TMPDIR/boots"
    echo 1 > "$BOOTS"
    cat > "$BIN/ssh" <<'EOF'
#!/bin/bash
cmd="${*: -1}"
echo "ssh $cmd" >> "$LOG"
r="$BATS_TEST_TMPDIR/restarting"
case "$cmd" in
  "id -un") echo vagrant ;;
  "mktemp /tmp/guest-aqua.XXXXXX") echo /tmp/guest-aqua.abc123 ;;
  "cat > /tmp/guest-aqua.abc123") cat > "$BATS_TEST_TMPDIR/guest-script" ;;
  "sudo sh /tmp/guest-aqua.abc123 vagrant"*)
    [ -z "${HOST_GUEST_FAIL:-}" ] || { echo "aqua-session: dscl . -authonly did not accept the password"; exit 1; } ;;
  "sysctl -n kern.boottime")
    if [ -e "$r" ] && [ -z "${HOST_NEVER_BACK:-}" ]; then
      n=$(($(cat "$r") + 1)); echo "$n" > "$r"
      [ "$n" -le "${OLD_ANSWERS:-3}" ] || echo 2 > "$BOOTS"
    fi
    echo "{ sec = $(cat "$BOOTS"), usec = 0 }" ;;
  *guest-macosx-shutdown\ -r*) echo 0 > "$r"; exit 255 ;;
  "/usr/local/bin/guest-macosx-aqua --check")
    [ "$(cat "$BOOTS")" = 2 ] || { echo "checked the guest going down" >> "$LOG"; echo "Aqua Dock Finder"; exit 0; }
    if [ -n "${HOST_NEVER_AQUA:-}" ]; then echo "Background"; exit 1; fi
    echo "Aqua Dock Finder" ;;
  "/usr/local/bin/guest-macosx-aqua launchctl managername") echo Aqua ;;
  # 10.9's sshd PATH has no /usr/local/bin: a bare guest-macosx-aqua is not found there
  *) echo "bash: ${cmd%% *}: command not found" >&2; exit 127 ;;
esac
EOF
    chmod +x "$BIN/ssh"
}
host() { PATH="$BIN:$PATH" bash "$REPO/scripts/aqua.sh"; }

@test "the host side: the guest script goes in as root, then a restart, then the session is waited for" {
    host_setup
    run host
    [ "$status" -eq 0 ] || { echo "$output"; cat "$LOG"; false; }
    cmp "$BATS_TEST_TMPDIR/guest-script" "$REPO/scripts/guest-aqua.sh"
    g=$(grep -n "^ssh sudo sh /tmp/guest-aqua.abc123 vagrant" "$LOG" | cut -d: -f1)
    r=$(grep -n "^ssh .*guest-macosx-shutdown -r" "$LOG" | cut -d: -f1)
    c=$(grep -nxF "ssh /usr/local/bin/guest-macosx-aqua --check" "$LOG" | head -1 | cut -d: -f1)
    [ -n "$g" ] && [ -n "$r" ] && [ -n "$c" ] && [ "$g" -lt "$r" ] && [ "$r" -lt "$c" ] || { cat "$LOG"; false; }
    [[ "$output" == *"Aqua"* ]] || { echo "$output"; false; }
}

# spec: run.sh -- piped into the guest's sh, a command that read stdin would swallow the rest of
#       the script, so it goes to a file first and runs from there
@test "the script reaches the guest as a file it runs from, not on sh's stdin, and is removed" {
    host_setup
    run host
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    grep -qxF 'ssh sudo sh /tmp/guest-aqua.abc123 vagrant; s=$?; rm -f /tmp/guest-aqua.abc123; exit $s' "$LOG" || { cat "$LOG"; false; }
}

@test "the check waits for the restarted guest, not the one going down, which still answers for a while" {
    host_setup
    OLD_ANSWERS=4 run host
    [ "$status" -eq 0 ] || { echo "$output"; cat "$LOG"; false; }
    ! grep -qx "checked the guest going down" "$LOG" || { cat "$LOG"; false; }
}

@test "a guest that does not come back from its restart fails within the timeout, naming it" {
    host_setup
    HOST_NEVER_BACK=1 MVM_SSH_TIMEOUT=1 run host
    [ "$status" -eq 1 ]
    [[ "$output" == *"::error title=mavericks-vm::starting the Aqua session: the guest did not come back from its restart within 1s"* ]] || { echo "$output"; false; }
}

@test "a guest script that fails is one ::error naming the step, and no restart" {
    host_setup
    HOST_GUEST_FAIL=1 run host
    [ "$status" -eq 1 ]
    [ "$(grep -c '::error' <<< "$output")" -eq 1 ] || { echo "$output"; false; }
    [[ "$output" == *"::error title=mavericks-vm::starting the Aqua session: "*"did not accept"* ]] || { echo "$output"; false; }
    ! grep -q "guest-macosx-shutdown -r" "$LOG" || false
}

@test "a session that never reaches Aqua fails within the timeout, saying what the guest last said" {
    host_setup
    HOST_NEVER_AQUA=1 run host
    [ "$status" -eq 1 ]
    [[ "$output" == *"::error title=mavericks-vm::starting the Aqua session: no Aqua session within 2s; the guest last said: Background"* ]] || { echo "$output"; false; }
}
