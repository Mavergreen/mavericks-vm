#!/bin/bash
# platform: GitHub's Linux runners only (bash, GNU coreutils) -- this Action runs nowhere else
#   usage: key.sh --base | --layer | --prepared
#          env in:  MVM_ROOT (default: this repo); for --prepared, MVM_PREPARE,
#                   MVM_CACHE_AFTER_PREPARE_SUFFIX and MVM_CPU_MODEL; for every key, curl and the
#                   network (the plugin's base-recipe asset)
#          out:     the cache key, 64 hex digits
set -euo pipefail

mode="${1:-}"
case "$mode" in
  --base|--layer|--prepared) ;;
  *) echo "usage: key.sh --base | --layer | --prepared" >&2; exit 2 ;;
esac

root="${MVM_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
pin="$(tr -d '[:space:]' < "$root/components/packer-plugin-macosx/version" 2>/dev/null || true)"
[ -n "$pin" ] || { echo "key.sh: no packer-plugin-macosx release in $root/components/packer-plugin-macosx/version" >&2; exit 1; }
[ -f "$root/box.pkrvars.hcl" ] || { echo "key.sh: no $root/box.pkrvars.hcl" >&2; exit 1; }
recipe="$(tr -d '[:space:]' < "$root/scripts/guest-recipe" 2>/dev/null || true)"
[ -n "$recipe" ] || { echo "key.sh: no guest recipe in $root/scripts/guest-recipe" >&2; exit 1; }

# spec: tests/key.bats -- three keys, each from the one below it. The base follows the plugin's
#       base recipe (a release asset: one line of 64 hex digits that moves only when what the base
#       image is made of moves), the box settings the build is given and the guest recipe, so a plugin
#       release that leaves the recipe alone keeps the base. The layer adds the plugin release itself.
#       The prepared adds prepare. Runtime inputs (mem, cpu, nat, sync) are in none of them
base_key() {
  asset="packer-plugin-macosx_${pin}_mavericks_base_recipe.txt"
  url="https://github.com/Mavergreen/packer-plugin-macosx/releases/download/$pin/$asset"
  plugin_recipe="$(curl -fsSL --retry 3 --max-time 60 "$url" | tr -d '[:space:]')" || plugin_recipe=""
  [[ "$plugin_recipe" =~ ^[0-9a-f]{64}$ ]] || {
    echo "key.sh: no base recipe (64 hex digits) in $asset of packer-plugin-macosx release $pin ($url)" >&2
    exit 1
  }
  {
    printf 'recipe-of-plugin=%s\n' "$plugin_recipe"
    printf 'box=%s\n' "$(sha256sum < "$root/box.pkrvars.hcl" | cut -d' ' -f1)"
    printf 'recipe=%s\n' "$recipe"
  } | sha256sum | cut -d' ' -f1
}

layer_key() {
  { printf 'base=%s\n' "$(base_key)"; printf 'plugin=%s\n' "$pin"; } | sha256sum | cut -d' ' -f1
}

prepared_key() {
  {
    printf 'layer=%s\n' "$(layer_key)"
    printf 'prepare=%s\n' "$(printf '%s' "${MVM_PREPARE:-}" | sha256sum | cut -d' ' -f1)"
    printf 'suffix=%s\n' "${MVM_CACHE_AFTER_PREPARE_SUFFIX:-}"
    # spec: tests/key.bats -- prepare ran on this guest CPU, and a build in it may have probed it
    printf 'cpu-model=%s\n' "${MVM_CPU_MODEL:-}"
  } | sha256sum | cut -d' ' -f1
}

case "$mode" in
  --base) base_key ;;
  --layer) layer_key ;;
  --prepared) prepared_key ;;
esac
