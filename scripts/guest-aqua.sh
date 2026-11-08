#!/bin/sh
# platform: Mac OS X 10.9's /bin/sh, as root in the guest (aqua.sh copies it in and runs "sudo sh <it> <user>")
#   usage: guest-aqua.sh <user>
#          env in:  GUEST_AQUA_ROOT (tests only: a directory standing for /)
#          out:     <user> with a random password that only this script ever held, verified with
#                   dscl, in /etc/kcpassword (root's only); autoLoginUser <user>; Setup Assistant's
#                   first-login screens marked seen for <user>; /usr/local/bin/guest-macosx-aqua;
#                   the login itself is at the next boot, which aqua.sh starts; on any failure,
#                   exit 1 after one line naming the step
# spec: tests/aqua.bats -- the password exists only here and in the guest: generated in the guest,
#       never printed, never on the runner. The guest is disposable and this step runs after any
#       snapshot, so no cached image ever holds it (main.sh). It is in dscl's argv for the length of
#       two dscl calls, as packer-plugin-macosx's first boot puts a configured one (its
#       configuration register, "auto-login"): dscl takes it no other way without a terminal.
set -u
root="${GUEST_AQUA_ROOT:-}"
user="${1:?usage: guest-aqua.sh <user>}"
case "$user" in *[!a-z0-9_]*|'') echo "aqua-session: not a user name: $user"; exit 1 ;; esac
kc="$root/private/etc/kcpassword"
lwprefs="$root/Library/Preferences/com.apple.loginwindow"
fail() { echo "aqua-session: $1 failed"; exit 1; }

uid="$(id -u "$user")" || fail "finding $user's uid"
pw="$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20)"
[ "${#pw}" -eq 20 ] || fail "making a random password"
dscl . -passwd "/Users/$user" "$pw" || fail "dscl . -passwd for $user"
dscl . -authonly "$user" "$pw" || { echo "aqua-session: dscl . -authonly did not accept the password it was just given"; exit 1; }

# spec: packer-plugin-macosx assets/guest/firstboot.sh kcpassword_encode -- the password and a NUL,
#       each byte XORed with the key, then the key's bytes to a multiple of 12 (MEASURED there: the
#       guest logged in with these bytes)
rm -f "$kc"
(
  umask 077
  printf '%s' "$pw" | perl -e '
    my @k = (0x7D,0x89,0x52,0x23,0xD2,0xBC,0xDD,0xEA,0xA3,0xB9,0x1F);
    my $p = do { local $/; <STDIN> }; $p .= "\0"; my @o;
    for my $i (0 .. length($p) - 1) { push @o, ord(substr($p, $i, 1)) ^ $k[$i % 11]; }
    push @o, $k[scalar(@o) % 11] while scalar(@o) % 12;
    print pack("C*", @o);' > "$kc"
)
pw=""
[ -s "$kc" ] || { rm -f "$kc"; fail "writing $kc"; }
defaults write "$lwprefs" autoLoginUser "$user" || fail "turning on auto-login (autoLoginUser)"

# spec: tests/aqua.bats -- MEASURED 2026-11-07: without these the first login stopped at Setup
#       Assistant's Apple ID screen, with no Dock or Finder
sudo -u "$user" defaults write com.apple.SetupAssistant DidSeeCloudSetup -bool true \
  || fail "marking Setup Assistant's iCloud screen seen (DidSeeCloudSetup)"
sudo -u "$user" defaults write com.apple.SetupAssistant LastSeenCloudProductVersion 10.9.5 \
  || fail "marking Setup Assistant's screens seen for 10.9.5 (LastSeenCloudProductVersion)"

# spec: tests/aqua.bats -- MEASURED 2026-11-07: from root, `launchctl asuser <uid>` said Background;
#       `launchctl bsexec <the user's loginwindow>` said Aqua, and needs root (task_for_pid). The
#       user is found by uid: ps's user column is 8 characters wide.
helper="$root/usr/local/bin/guest-macosx-aqua"
mkdir -p "$(dirname "$helper")" || fail "making $(dirname "$helper")"
sed -e "s/@USER@/$user/g" -e "s/@UID@/$uid/g" > "$helper" <<'HELPER' || fail "writing $helper"
#!/bin/sh
# guest-macosx-aqua <command> [args...]: runs the command in @USER@'s Aqua session, as @USER@,
#   here, with this environment as sudo -E passes it (installed by mavericks-vm's aqua-session)
# guest-macosx-aqua --check: says the session's state; exits 0 once it is Aqua with Dock and Finder
[ $# -gt 0 ] || { echo "usage: guest-macosx-aqua <command> [args...] | --check" >&2; exit 2; }
lw="$(ps -axo pid=,uid=,comm= | awk '$2 == @UID@ && $3 ~ /\/loginwindow$/ { print $1; exit }')"
if [ "$1" = --check ]; then
  [ -n "$lw" ] || { echo "no loginwindow of @USER@'s"; exit 1; }
  m="$(sudo launchctl bsexec "$lw" launchctl managername 2>&1)"
  up="$(ps -axo pid=,uid=,comm= | awk '$2 == @UID@ && $3 ~ /\/(Dock|Finder)$/ { sub(/.*\//, "", $3); print $3 }' | sort -u | tr '\n' ' ')"
  echo "$m $up"
  [ "$m" = Aqua ] && [ "$up" = "Dock Finder " ]
  exit
fi
[ -n "$lw" ] || { echo "guest-macosx-aqua: @USER@ has no Aqua session (no loginwindow of theirs)" >&2; exit 1; }
exec sudo -E launchctl bsexec "$lw" sudo -E -u @USER@ "$@"
HELPER
chmod 755 "$helper" || fail "making $helper executable"
echo "aqua-session: auto-login on for $user, with a password only this guest holds; guest-macosx-aqua installed"
