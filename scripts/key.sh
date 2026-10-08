#!/bin/bash
# platform: GitHub's Linux runners only (bash, GNU coreutils) -- this Action runs nowhere else
#   usage: key.sh [--prepared]
#          env in:  MVM_ROOT (default: this repo); for --prepared, MVM_PREPARE,
#                   MVM_CACHE_AFTER_PREPARE_SUFFIX and MVM_CPU_MODEL
#          out:     the cache key, 64 hex digits
set -euo pipefail

root="${MVM_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
pin="$(tr -d '[:space:]' < "$root/components/packer-plugin-macosx/version" 2>/dev/null || true)"
[ -n "$pin" ] || { echo "key.sh: no packer-plugin-macosx release in $root/components/packer-plugin-macosx/version" >&2; exit 1; }
[ -f "$root/box.pkrvars.hcl" ] || { echo "key.sh: no $root/box.pkrvars.hcl" >&2; exit 1; }
recipe="$(tr -d '[:space:]' < "$root/scripts/guest-recipe" 2>/dev/null || true)"
[ -n "$recipe" ] || { echo "key.sh: no guest recipe in $root/scripts/guest-recipe" >&2; exit 1; }

# spec: tests/key.bats -- the plugin release is a declared state (packer-plugin-macosx decision
#       0012), so it, the box settings the build is given, and the guest recipe are the whole of what
#       the cached guest is made of; runtime inputs (mem, cpu, cpu-model, nat, sync) are not
{
  printf 'plugin=%s\n' "$pin"
  printf 'box=%s\n' "$(sha256sum < "$root/box.pkrvars.hcl" | cut -d' ' -f1)"
  printf 'recipe=%s\n' "$recipe"
  if [ "${1:-}" = --prepared ]; then
    printf 'prepare=%s\n' "$(printf '%s' "${MVM_PREPARE:-}" | sha256sum | cut -d' ' -f1)"
    printf 'suffix=%s\n' "${MVM_CACHE_AFTER_PREPARE_SUFFIX:-}"
    # spec: tests/key.bats -- prepare ran on this guest CPU, and a build in it may have probed it
    printf 'cpu-model=%s\n' "${MVM_CPU_MODEL:-}"
  fi
} | sha256sum | cut -d' ' -f1
