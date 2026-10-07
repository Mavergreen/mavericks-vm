#!/bin/bash
# platform: GitHub's Linux runners only (bash, rsync, OpenSSH, GNU tar) -- this Action runs nowhere else
#   usage: sync.sh in|out
#          env in:  GITHUB_WORKSPACE, MVM_SYNC (rsync|scp|tar|no), MVM_COPYBACK (for out)
#          out:     the workspace in the guest at the same path (in), or back on the runner (out)
set -euo pipefail

case "${1:-}" in in|out) ;; *) echo "usage: sync.sh in|out" >&2; exit 2 ;; esac
ws="${GITHUB_WORKSPACE:?sync.sh: GITHUB_WORKSPACE is unset}"
cfg="$HOME/.ssh/config"
ssh_() { ssh -F "$cfg" mavericks "$@"; }
wsq="$(printf '%q' "$ws")"

if [ "$1" = in ]; then
  # spec: tests/run.bats -- vmactions runs in the guest at the runner's own workspace path, so
  #       the path is made whatever sync is; sync: no only leaves it empty
  # platform: 10.9 mounts auto_home on /home, where mkdir fails "Operation not supported", and
  #           GitHub's workspaces live under /home/runner/work; switching the map off and
  #           re-reading it frees /home (MEASURED 2026-10-06 on a 10.9.5 guest). Only the
  #           throwaway overlay changes.
  ssh_ "if grep -q '^/home' /etc/auto_master 2>/dev/null; then sudo sed -i '' 's|^/home|#/home|' /etc/auto_master && sudo automount -vc > /dev/null; fi"
  ssh_ "sudo mkdir -p $wsq && sudo chown vagrant $wsq"
  case "${MVM_SYNC:-rsync}" in
    no) ;;
    rsync) rsync -a --delete -e "ssh -F $cfg" "$ws/" "mavericks:$ws/" ;;
    scp) scp -F "$cfg" -r -q "$ws/." "mavericks:$ws/" ;;
    # platform: 10.9's bsdtar reads pax, which carries names longer than ustar's 100 bytes
    tar) tar -C "$ws" --format=pax -cf - . | ssh_ "tar -C $wsq -xf -" ;;
  esac
else
  [ "${MVM_COPYBACK:-true}" = true ] || exit 0
  case "${MVM_SYNC:-rsync}" in
    rsync) rsync -a -e "ssh -F $cfg" "mavericks:$ws/" "$ws/" ;;
    scp) scp -F "$cfg" -r -q "mavericks:$ws/." "$ws/" ;;
    tar) ssh_ "tar -C $wsq -cf - ." | tar -C "$ws" -xf - ;;
    no) ;;
  esac
fi
