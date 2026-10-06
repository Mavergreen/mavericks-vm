#!/bin/sh
# platform: host-agnostic (POSIX sh, git)
#   usage: version.sh
#          out:  FULL=<line>.<commit count> and TAG=v<that>; UPSTREAM_VERSION holds the line
# spec: Mavergreen/shipyard scripts/shipyard-version.sh -- the same rule, for this repo: consumers
#       ride the moving @v1, and every push to main is a release (INGREDIENTS.md's release model)
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
line="$(sed -n '1p' "$root/UPSTREAM_VERSION" | tr -d ' \t')"
case "$line" in
  [0-9]*.[0-9]*.*) echo "version.sh: UPSTREAM_VERSION holds the LINE (major.minor), not a full version: $line" >&2; exit 1 ;;
  [0-9]*.[0-9]*) : ;;
  *) echo "version.sh: UPSTREAM_VERSION is not a major.minor line: $line" >&2; exit 1 ;;
esac
if [ "$(git -C "$root" rev-parse --is-shallow-repository)" = "true" ]; then
  echo "version.sh: $root is a shallow clone; the commit count is meaningless there (fetch-depth: 0)" >&2
  exit 1
fi
count="$(git -C "$root" rev-list --count HEAD)"
echo "FULL=$line.$count"
echo "TAG=v$line.$count"
