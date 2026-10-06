#!/bin/bash
# platform: GitHub's Linux runners only (bash, GNU coreutils) -- this Action runs nowhere else
#   usage: inputs.sh
#          env in:  MVM_IN_* (action.yml passes every input; MVM_IN_HAS_IMAGE_KEY is whether
#                   image-key was given, never the key itself)
#          out:     MVM_* lines appended to $GITHUB_ENV, or an ::error:: and exit 1, writing nothing
set -euo pipefail

die() { echo "::error title=mavericks-vm::$*"; exit 1; }

# spec: tests/inputs.bats -- an empty image-key is a fork's pull request (or a repo without the
#       org secret), and must fail before anything is downloaded, built or pushed
[ "${MVM_IN_HAS_IMAGE_KEY:-false}" = true ] \
  || die "image-key is empty. It decrypts the cached guest and is the org secret MAVERICKS_VM_KEY; a pull request from a fork never receives secrets, so a fork cannot run Mavericks tests here"

case "${MVM_IN_OSNAME:-mavericks}" in mavericks) ;; *) die "osname: only mavericks is supported (got '${MVM_IN_OSNAME}')" ;; esac
case "${MVM_IN_RELEASE:-10.9}" in 10.9) ;; *) die "release: only 10.9 is supported (got '${MVM_IN_RELEASE}')" ;; esac
case "${MVM_IN_ARCH:-x86_64}" in x86_64) ;; *) die "arch: only x86_64 is supported (got '${MVM_IN_ARCH}')" ;; esac

posint() {  # $1 = input name, $2 = value
  case "$2" in ''|*[!0-9]*|0*) die "$1: want a positive whole number (got '$2')" ;; esac
}
posint mem "${MVM_IN_MEM:-}"
posint cpu "${MVM_IN_CPU:-}"

bool() {  # $1 = input name, $2 = value, $3 = default when empty
  v="${2:-$3}"
  case "$v" in true|false) printf '%s' "$v" ;; *) die "$1: want true or false (got '$2')" ;; esac
}
copyback="$(bool copyback "${MVM_IN_COPYBACK:-}" true)"
disable_cache="$(bool disable-cache "${MVM_IN_DISABLE_CACHE:-}" false)"
after_prepare="$(bool cache-after-prepare "${MVM_IN_CACHE_AFTER_PREPARE:-}" false)"
debug="$(bool debug "${MVM_IN_DEBUG:-}" false)"
sync_time="$(bool sync-time "${MVM_IN_SYNC_TIME:-}" false)"
debug_on_error="$(bool debug-on-error "${MVM_IN_DEBUG_ON_ERROR:-}" false)"

sync="${MVM_IN_SYNC:-rsync}"
case "$sync" in
  rsync|scp|tar|no) ;;
  # platform: stock 10.9 has no FUSE, so the guest cannot mount anything over sshfs
  sshfs) die "sync: sshfs is not supported -- stock Mac OS X 10.9 has no FUSE; use rsync (the default), scp, tar or no" ;;
  nfs) die "sync: nfs is not yet supported; use rsync (the default), scp, tar or no" ;;
  *) die "sync: want rsync, scp, tar or no (got '$sync')" ;;
esac

safe() {  # $1 = input name, $2 = value: one argv word, no shell metacharacters
  case "$2" in ''|*[!A-Za-z0-9.,+=_:-]*) die "$1: '$2' may hold only letters, digits and . , + = _ : -" ;; esac
}
safe cpu-model "${MVM_IN_CPU_MODEL:-}"
# spec: tests/inputs.bats -- a runner is AMD or Intel by chance, and 10.9 hangs on AMD unless the
#       guest's CPU says GenuineIntel (packer-plugin-macosx docs/host-profile.md G2), so a cpu-model
#       naming no vendor gets that one, right after its model name
cpu_model="$MVM_IN_CPU_MODEL"
case ",$cpu_model," in
  *,vendor=*) ;;
  *) model="${cpu_model%%,*}"; cpu_model="$model,vendor=GenuineIntel${cpu_model#"$model"}" ;;
esac
safe custom-shell-name "${MVM_IN_CUSTOM_SHELL_NAME:-mavericks}"

envs=""
for name in ${MVM_IN_ENVS:-}; do
  case "$name" in [A-Za-z_]*) ;; *) die "envs: '$name' is not a variable name" ;; esac
  case "$name" in *[!A-Za-z0-9_]*) die "envs: '$name' is not a variable name" ;; esac
  envs="${envs:+$envs }$name"
done

# spec: tests/inputs.bats -- vmactions' nat lines, '"8080": "80"' or 'udp:"8081": "80"', become
#       proto:host:guest words, the shape QEMU's hostfwd wants
nat=""
while IFS= read -r line; do
  line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
  [ -n "$line" ] || continue
  if [[ "$line" =~ ^(udp:|tcp:)?\"([0-9]+)\":[[:space:]]*\"([0-9]+)\"$ ]]; then
    proto="${BASH_REMATCH[1]%:}"; nat="${nat:+$nat }${proto:-tcp}:${BASH_REMATCH[2]}:${BASH_REMATCH[3]}"
  else
    die "nat: '$line' is not a \"host\": \"guest\" port line (vmactions' shape; udp: allowed)"
  fi
done <<< "${MVM_IN_NAT:-}"

data_dir="${MVM_IN_DATA_DIR:-/mnt/mavericks-vm}"
cache_dir="${MVM_IN_CACHE_DIR:-$data_dir/cache}"
case "$data_dir$cache_dir" in *[[:space:]]*) die "data-dir and cache-dir may not contain whitespace" ;; esac

# spec: tests/inputs.bats -- usesh is accepted and ignored, as vmactions does; it writes nothing
{
  echo "MVM_MEM=$MVM_IN_MEM"
  echo "MVM_CPU=$MVM_IN_CPU"
  echo "MVM_CPU_MODEL=$cpu_model"
  echo "MVM_SYNC=$sync"
  echo "MVM_COPYBACK=$copyback"
  echo "MVM_ENVS=$envs"
  echo "MVM_NAT=$nat"
  echo "MVM_DISABLE_CACHE=$disable_cache"
  echo "MVM_CACHE_AFTER_PREPARE=$after_prepare"
  echo "MVM_CACHE_AFTER_PREPARE_SUFFIX=${MVM_IN_CACHE_AFTER_PREPARE_KEY_SUFFIX:-}"
  echo "MVM_SHELL_NAME=${MVM_IN_CUSTOM_SHELL_NAME:-mavericks}"
  echo "MVM_DATA_DIR=$data_dir"
  echo "MVM_CACHE_DIR=$cache_dir"
  echo "MVM_DEBUG=$debug"
  echo "MVM_SYNC_TIME=$sync_time"
  echo "MVM_DEBUG_ON_ERROR=$debug_on_error"
} >> "$GITHUB_ENV"
