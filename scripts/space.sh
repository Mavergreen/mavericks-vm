#!/bin/bash
# platform: GitHub's Linux runners only (bash, GNU df) -- this Action runs nowhere else
#   usage: space.sh hit|miss|prepare
#          env in:  MVM_DATA_DIR; MVM_SPACE_AVAILABLE_KIB (tests only: instead of df)
#          out:     exit 0, or an ::error:: naming data-dir, the room there and the room needed
set -euo pipefail

case "${1:-}" in hit|miss|prepare) ;; *) echo "usage: space.sh hit|miss|prepare" >&2; exit 2 ;; esac
root="$(cd "$(dirname "$0")/.." && pwd)"
dir="${MVM_DATA_DIR:?space.sh: MVM_DATA_DIR is unset}"
mkdir -p "$dir"
need_gib="$(sed -n "s/^$1 //p" "$root/scripts/space-needed")"
avail_kib="${MVM_SPACE_AVAILABLE_KIB:-$(df -Pk "$dir" | awk 'NR == 2 { print $4 }')}"
avail_gib=$((avail_kib / 1024 / 1024))
# spec: tests/boot.bats -- refuse before starting, rather than fill the disk twenty minutes in
if [ "$avail_gib" -lt "$need_gib" ]; then
  echo "::error title=mavericks-vm::$dir has $avail_gib GiB free; a cache $1 needs $need_gib GiB more. Set data-dir to a larger volume, or use a larger runner."
  exit 1
fi
