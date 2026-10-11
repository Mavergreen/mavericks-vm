#!/bin/bash
# platform: GitHub's Linux runners only (bash, GNU coreutils) -- this Action runs nowhere else
#   usage: key.sh --base | --layer | --prepared | --recipe (the plugin's base recipe, which the keys
#          are made from; fetched once and handed back in MVM_BASE_RECIPE it is not fetched again)
#          env in:  MVM_ROOT (default: this repo); MVM_BASE_RECIPE (optional); for --prepared, MVM_PREPARE,
#                   MVM_CACHE_AFTER_PREPARE_SUFFIX and MVM_CPU_MODEL; for every key, curl and the
#                   network (the plugin's base-recipe asset)
#          out:     the cache key, 64 hex digits
set -euo pipefail

mode="${1:-}"
case "$mode" in
  --base|--layer|--prepared|--recipe) ;;
  *) echo "usage: key.sh --base | --layer | --prepared | --recipe" >&2; exit 2 ;;
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
#       release that leaves the recipe alone keeps the base. The layer adds the plugin release itself
#       and the layer recipe (scripts/layer-recipe, moved when the way this Action makes the layer
#       changes, so the layer alone is made again). The prepared adds prepare. Runtime inputs (mem,
#       cpu, nat, sync) are in none of them
plugin_recipe() {
  # spec: tests/key.bats -- a caller that fetched the recipe once hands it on in MVM_BASE_RECIPE,
  #       and it must be the same one line of 64 hex digits
  if [ -n "${MVM_BASE_RECIPE:-}" ]; then
    [[ "$MVM_BASE_RECIPE" =~ ^[0-9a-f]{64}$ ]] || {
      echo "key.sh: MVM_BASE_RECIPE is not one line of 64 hex digits" >&2
      exit 1
    }
    printf '%s' "$MVM_BASE_RECIPE"
    return
  fi
  asset="packer-plugin-macosx_${pin}_mavericks_base_recipe.txt"
  url="https://github.com/Mavergreen/packer-plugin-macosx/releases/download/$pin/$asset"
  plugin_recipe="$(curl -fsSL --retry 3 --max-time 60 "$url")" || plugin_recipe=""
  [[ "$plugin_recipe" =~ ^[0-9a-f]{64}$ ]] || {
    echo "key.sh: no base recipe (one line of 64 hex digits) in $asset of packer-plugin-macosx release $pin ($url)" >&2
    exit 1
  }
  printf '%s' "$plugin_recipe"
}

# spec: tests/key.bats -- each key takes the one below it in a variable first: an exit inside a
#       command substitution in printf's arguments would not stop the key from being made of nothing
base_key() {
  local plugin_recipe_value
  plugin_recipe_value="$(plugin_recipe)" || exit 1
  {
    printf 'recipe-of-plugin=%s\n' "$plugin_recipe_value"
    printf 'box=%s\n' "$(sha256sum < "$root/box.pkrvars.hcl" | cut -d' ' -f1)"
    printf 'recipe=%s\n' "$recipe"
  } | sha256sum | cut -d' ' -f1
}

layer_key() {
  local base layer_recipe
  layer_recipe="$(tr -d '[:space:]' < "$root/scripts/layer-recipe" 2>/dev/null || true)"
  [ -n "$layer_recipe" ] || { echo "key.sh: no layer recipe in $root/scripts/layer-recipe" >&2; exit 1; }
  base="$(base_key)" || exit 1
  {
    printf 'base=%s\n' "$base"
    printf 'plugin=%s\n' "$pin"
    printf 'layer-recipe=%s\n' "$layer_recipe"
  } | sha256sum | cut -d' ' -f1
}

prepared_key() {
  local layer
  layer="$(layer_key)" || exit 1
  {
    printf 'layer=%s\n' "$layer"
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
  --recipe) plugin_recipe; echo ;;
esac
