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
{
  for n in ${MVM_ENVS:-}; do
    if [ -n "${!n+set}" ]; then printf 'export %s=%q\n' "$n" "${!n}"; fi
  done
  printf 'cd %q || exit 1\n' "$ws"
  cat "$1"
} | ssh -F "$HOME/.ssh/config" mavericks 'sh -e -s'
