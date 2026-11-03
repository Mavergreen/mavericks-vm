#!/bin/bash
# platform: GitHub's Linux runners only (bash, GNU tar, curl, unzip) -- this Action runs nowhere else
#   usage: build.sh <template> <dir> [<base-dir>]
#          <template> is mavericks, or mavericks-aquatransport (which needs <base-dir>: an unpacked
#          Mavericks box, read and never written)
#          env in:  MVM_DATA_DIR, MVM_CACHE_DIR; MVM_LOG_DIR (optional: where a failed build keeps
#                   its logs, under <template>, by guest-logs.sh); MVM_BUILD_TIMEOUT (optional: the
#                   build's wall-clock bound in seconds, 3 h for the base and 2.5 h for the layer)
#          out:     the guest's box contents (box_0.img, OVMF_CODE.fd, OVMF_VARS.fd, opencore.img,
#                   ...) in <dir>; on failure, the end of packer's output and exit 1, in plain
#                   lines: the caller (main.sh, layer.sh) names the image in the one ::error
set -euo pipefail

usage="usage: build.sh <template> <dir> [<base-dir>] (template: mavericks or mavericks-aquatransport)"
if [ $# -lt 2 ] || [ $# -gt 3 ]; then echo "$usage" >&2; exit 2; fi
template="$1"; out="$2"; base="${3:-}"
extra=()
# spec: tests/build.bats -- the base and the layer are built in one job, under GitHub's 6 h job limit: each
#       bound is above its template's own timeouts summed (the base's 1 h install_timeout and its updates;
#       the layer's 30 m SSH, 15 m install and 30 + 45 m verify), and the two leave time for the boot and run
case "$template" in
  mavericks)
    bound=10800
    [ -z "$base" ] || { echo "$usage (mavericks takes no <base-dir>)" >&2; exit 2; } ;;
  mavericks-aquatransport)
    bound=9000
    [ -n "$base" ] || { echo "$usage (mavericks-aquatransport needs <base-dir>)" >&2; exit 2; }
    # spec: tests/build.bats -- packer runs in the template dir, so a relative base would be
    #       resolved there; it is made absolute here
    base="$(realpath -m "$base")"
    extra=(-var "base_box=$base") ;;
  *) echo "$usage (unknown template: $template)" >&2; exit 2 ;;
esac
bound="${MVM_BUILD_TIMEOUT:-$bound}"
[[ "$bound" =~ ^[1-9][0-9]*$ ]] || { echo "build.sh: MVM_BUILD_TIMEOUT is a whole number of seconds, not '$bound'" >&2; exit 2; }
root="$(cd "$(dirname "$0")/.." && pwd)"
pin="$(tr -d '[:space:]' < "$root/components/packer-plugin-macosx/version")"
data="${MVM_DATA_DIR:?build.sh: MVM_DATA_DIR is unset}"
work="$data/build"
mkdir -p "$work" "${MVM_CACHE_DIR:?build.sh: MVM_CACHE_DIR is unset}"

zip="packer-plugin-macosx_${pin}_${template}_template.zip"
# spec: tests/build.bats -- bounded in time, as every download is: a stalled one fails, by name
curl -fsSL --retry 3 --connect-timeout 20 --max-time 120 -o "$work/$zip" \
  "https://github.com/Mavergreen/packer-plugin-macosx/releases/download/$pin/$zip" \
  || { echo "build.sh: downloading $zip failed"; exit 1; }
# spec: tests/build.bats -- the zip carries the failed-build reader that runs on this host (packer-plugin-macosx
#       docs/decisions/0040), so it is held to the SHA256SUMS the same release publishes; fail closed
sums="packer-plugin-macosx_${pin}_SHA256SUMS"
curl -fsSL --retry 3 --connect-timeout 20 --max-time 120 -o "$work/$sums" \
  "https://github.com/Mavergreen/packer-plugin-macosx/releases/download/$pin/$sums" \
  || { echo "build.sh: downloading $sums failed"; exit 1; }
want="$(awk -v z="$zip" '$2 == z { print $1; exit }' "$work/$sums")"
[ -n "$want" ] || { echo "build.sh: $zip is not in the release's SHA256SUMS"; exit 1; }
got="$( { sha256sum "$work/$zip" 2>/dev/null || shasum -a 256 "$work/$zip"; } | cut -d' ' -f1)"
[ "$got" = "$want" ] || { echo "build.sh: $zip does not match the release's SHA256SUMS"; exit 1; }
(cd "$work" && unzip -q -o "$zip")
tpl="$work/templates/$template"

export PACKER_PLUGIN_PATH="$data/packer-plugins" PACKER_CACHE_DIR="$MVM_CACHE_DIR" CHECKPOINT_DISABLE=1
# spec: tests/build.bats -- exactly the pinned plugin, installed before init: init alone would
#       take the newest release its ~> constraint allows, which may be newer than the cache key says
# spec: tests/build.bats -- packer asks GitHub's API for plugins, unauthenticated unless given a
#       token, and a shared runner's address runs out of unauthenticated requests; it reports a
#       failure on stdout, so that is shown when it fails (a repo-cache job failed in 0.6 s, without
#       a word, in Actions run 37635562340). The build itself, which starts QEMU, gets no token.
quiet() {  # $@ = a packer command, run with the job's token; its output only if it fails
  local out
  if ! out="$(PACKER_GITHUB_API_TOKEN="${MVM_TOKEN:-}" "$@" 2>&1)"; then
    echo "build.sh: $* failed:"
    printf '%s\n' "$out"
    return 1
  fi
}
quiet packer plugins install github.com/mavergreen/macosx "$pin"
(cd "$tpl" && quiet packer init .)

log="$work/packer-build.log"
# spec: tests/guest_logs.bats -- a failed build keeps what says why (Actions run 41250564922 kept
#       nothing): packer's debug log, with its times and scp's own words, and, with
#       -on-error=abort, the disk packer would otherwise delete, so guest-logs.sh can read the
#       guest's logs from it; packer never gets the image key or the token, since what it writes
#       is kept for people to read
(cd "$tpl" && exec env -u MVM_IMAGE_KEY -u MVM_TOKEN PACKER_LOG=1 PACKER_LOG_PATH="$work/packer-debug.log" \
  packer build -on-error=abort -var-file="$root/box.pkrvars.hcl" "${extra[@]}" .) > "$log" 2>&1 &
packer_pid=$!
keep_logs() {
  [ -n "${MVM_LOG_DIR:-}" ] || return 0
  bash "$root/scripts/guest-logs.sh" "$tpl" "$work" "$MVM_LOG_DIR/$template"
  echo "build.sh: packer's logs, the serial console and the guest's own logs are kept in $MVM_LOG_DIR/$template"
  sed 's/^/build.sh:   /' "$MVM_LOG_DIR/$template/summary.txt" 2>/dev/null
}
# spec: tests/build.bats -- Actions run 41501371727: the layer build hung 5 h 18 m, past every timeout of
#       packer's own, until the job's limit cancelled the step and kept nothing. At its bound a build is
#       read while it still runs (guest-logs.sh asks QMP and the live guest, then stops the QEMU), and only
#       then is packer stopped: stopped first, it would take its QEMU down with it.
deadline=$((SECONDS + bound))
while kill -0 "$packer_pid" 2>/dev/null && [ "$SECONDS" -lt "$deadline" ]; do sleep 1; done
if kill -0 "$packer_pid" 2>/dev/null; then
  echo "build.sh: building the guest ($template) with packer-plugin-macosx $pin outlived its bound of $bound s; read it, then stopped it. The end of packer's output:"
  tail -n 40 "$log"
  keep_logs
  kill -TERM "$packer_pid" 2>/dev/null
  for _ in $(seq 1 60); do kill -0 "$packer_pid" 2>/dev/null || break; sleep 1; done
  kill -KILL "$packer_pid" 2>/dev/null
  wait "$packer_pid" 2>/dev/null
  exit 1
fi
rc=0; wait "$packer_pid" || rc=$?
if [ "$rc" -ne 0 ]; then
  echo "build.sh: building the guest ($template) with packer-plugin-macosx $pin failed; the end of packer's output:"
  tail -n 40 "$log"
  keep_logs
  exit 1
fi

# spec: tests/build.bats -- the layer's box is the one named for the layer
case "$template" in
  mavericks-aquatransport) box="$(ls "$tpl"/output/*-aquatransport-*.box)" ;;
  *) box="$(ls "$tpl"/output/*.box)" ;;
esac
mkdir -p "$out"
tar -xzf "$box" -C "$out"
# spec: tests/build.bats -- the guest leaves the disk when the step ends: packer's output (the box,
#       and the image it was made from) goes as soon as the box is unpacked into <dir>, which
#       main.sh's own cleanup covers
find "$work" -mindepth 1 -delete
echo "build.sh: built the guest ($template) with packer-plugin-macosx $pin"
