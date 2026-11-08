#!/bin/bash
# platform: GitHub's Linux runners only (bash, OpenSSH) -- this Action runs nowhere else
#   usage: aqua.sh
#          env in:  MVM_SSH_TIMEOUT, MVM_SSH_INTERVAL (as boot.sh's: 600, 5), MVM_AQUA_TIMEOUT
#                   (default 180)
#          out:     the guest restarted and logged in to Aqua as the ssh user, guest-macosx-aqua
#                   reaching that session; on failure, exit 1 after the one ::error
# spec: tests/aqua.bats -- guest-aqua.sh does the guest's part as root; the login happens only at
#       boot, so this restarts the guest through its own shutdown helper and waits for the session
set -euo pipefail

step="starting the Aqua session"
named=false
err() {  # $1 = what went wrong; a workflow command is one line, so % CR LF are encoded
  local m="${1//'%'/%25}"; m="${m//$'\r'/%0D}"; m="${m//$'\n'/%0A}"
  named=true
  echo "::error title=mavericks-vm::$step: $m"
}
unforeseen() { local rc=$?; [ "$rc" -eq 0 ] || [ "$named" = true ] || echo "::error title=mavericks-vm::$step failed"; }
trap unforeseen EXIT
here="$(cd "$(dirname "$0")" && pwd)"
g() { ssh -F "$HOME/.ssh/config" mavericks "$@"; }
every="${MVM_SSH_INTERVAL:-5}"

user="$(g -n 'id -un')"
# spec: tests/aqua.bats -- as run.sh does: the script goes to a file in the guest and runs from
#       there, since piped into sh, a command that read stdin would swallow the rest of it
f="$(g -n 'mktemp /tmp/guest-aqua.XXXXXX')"
g "cat > $f" < "$here/guest-aqua.sh"
if ! said="$(g -n "sudo sh $f $user; s=\$?; rm -f $f; exit \$s" 2>&1)"; then
  err "$said"
  exit 1
fi
echo "$said"

booted="$(g -n 'sysctl -n kern.boottime')"
g -n 'sudo /usr/local/sbin/guest-macosx-shutdown -r' || true
# spec: tests/aqua.bats -- the guest going down still answers for a moment; only a new boot time
#       is the restarted guest
limit="${MVM_SSH_TIMEOUT:-600}" start=$SECONDS
until now="$(g -n 'sysctl -n kern.boottime' 2>/dev/null)" && [ -n "$now" ] && [ "$now" != "$booted" ]; do
  if [ $((SECONDS - start)) -ge "$limit" ]; then err "the guest did not come back from its restart within ${limit}s"; exit 1; fi
  sleep "$every"
done
echo "aqua.sh: the guest restarted after $((SECONDS - start))s"

# platform: 10.9's sshd gives a command PATH=/usr/bin:/bin:/usr/sbin:/sbin, without /usr/local/bin
#           (MEASURED 2026-11-07), so the helper is named by its path, as guest-macosx-shutdown is
limit="${MVM_AQUA_TIMEOUT:-180}" start=$SECONDS last=""
until last="$(g -n '/usr/local/bin/guest-macosx-aqua --check' 2>&1)"; do
  if [ $((SECONDS - start)) -ge "$limit" ]; then err "no Aqua session within ${limit}s; the guest last said: $last"; exit 1; fi
  sleep "$every"
done
echo "aqua.sh: $user is logged in after $((SECONDS - start))s ($last); launchctl managername in guest-macosx-aqua: $(g -n '/usr/local/bin/guest-macosx-aqua launchctl managername')"
