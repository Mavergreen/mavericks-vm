#!/bin/bash
# platform: GitHub's Linux runners only (bash) -- this Action runs nowhere else
#   usage: shell-wrapper.sh --install      put <custom-shell-name> on the job's PATH
#          shell-wrapper.sh <script-file>  what "shell: <name> {0}" runs: sync in, run, sync out
#          env in:  MVM_DATA_DIR, MVM_SHELL_NAME, and what sync.sh and run.sh read
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
if [ "${1:-}" = --install ]; then
  bin="${MVM_DATA_DIR:?}/bin"
  mkdir -p "$bin"
  printf '#!/bin/bash\nexec bash %q "$@"\n' "$here/shell-wrapper.sh" > "$bin/${MVM_SHELL_NAME:-mavericks}"
  chmod +x "$bin/${MVM_SHELL_NAME:-mavericks}"
  echo "$bin" >> "${GITHUB_PATH:?}"
  exit 0
fi
[ $# -eq 1 ] || { echo "usage: shell-wrapper.sh --install | <script-file>" >&2; exit 2; }
bash "$here/sync.sh" in || exit 1
bash "$here/run.sh" "$1"; status=$?
# spec: tests/run.bats -- a failing step still copies back, then reports its own status
bash "$here/sync.sh" out || exit 1
exit "$status"
