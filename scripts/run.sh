#!/bin/bash
# platform: GitHub's Linux runners only (bash, OpenSSH) -- this Action runs nowhere else
#   usage: run.sh <script-file>
#          env in:  GITHUB_WORKSPACE, MVM_ENVS, and each variable MVM_ENVS names
#          out:     the script's exit status, having run in the guest's workspace with sh -e
set -euo pipefail

[ $# -eq 1 ] || { echo "usage: run.sh <script-file>" >&2; exit 2; }
ws="${GITHUB_WORKSPACE:?run.sh: GITHUB_WORKSPACE is unset}"
# spec: tests/run.bats -- the envs' values travel inside the script, on ssh's stdin, never as
#       arguments: a secret passed in envs would otherwise show in the runner's process list
# spec: tests/run.bats -- the script goes to a file in the guest first and runs from there with
#       nothing on stdin: piped into the guest's sh, a command in it that read stdin swallowed the
#       rest of the script and the step passed (10.9's sh is bash, which reads a pipe byte by byte)
cfg="$HOME/.ssh/config"
f="$(ssh -F "$cfg" -n mavericks 'mktemp /tmp/mavericks-vm-run.XXXXXX')" || exit 1
{
  for n in ${MVM_ENVS:-}; do
    if [ -n "${!n+set}" ]; then printf 'export %s=%q\n' "$n" "${!n}"; fi
  done
  printf 'cd %q || exit 1\n' "$ws"
  cat "$1"
} | ssh -F "$cfg" mavericks "cat > $f" || exit 1
ssh -F "$cfg" -n mavericks "sh -e $f; s=\$?; rm -f $f; exit \$s"
