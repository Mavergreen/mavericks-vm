#!/bin/bash
# platform: GitHub's Linux runners only (bash, GNU tar, curl, unzip) -- this Action runs nowhere else
#   usage: build.sh <template> <dir> [<base-dir>]
#          <template> is mavericks, or mavericks-aquatransport (which needs <base-dir>: an unpacked
#          Mavericks box, read and never written)
#          env in:  MVM_DATA_DIR, MVM_CACHE_DIR; MVM_LOG_DIR (optional: where a failed build keeps
#                   its logs, under <template>, by guest-logs.sh)
#          out:     the guest's box contents (box_0.img, OVMF_CODE.fd, OVMF_VARS.fd, opencore.img,
#                   ...) in <dir>; on failure, the end of packer's output and exit 1, in plain
#                   lines: the caller (main.sh, layer.sh) names the image in the one ::error
set -euo pipefail

usage="usage: build.sh <template> <dir> [<base-dir>] (template: mavericks or mavericks-aquatransport)"
if [ $# -lt 2 ] || [ $# -gt 3 ]; then echo "$usage" >&2; exit 2; fi
template="$1"; out="$2"; base="${3:-}"
extra=()
case "$template" in
  mavericks) [ -z "$base" ] || { echo "$usage (mavericks takes no <base-dir>)" >&2; exit 2; } ;;
  mavericks-aquatransport)
    [ -n "$base" ] || { echo "$usage (mavericks-aquatransport needs <base-dir>)" >&2; exit 2; }
    # spec: tests/build.bats -- packer runs in the template dir, so a relative base would be
    #       resolved there; it is made absolute here
    base="$(realpath -m "$base")"
    extra=(-var "base_box=$base") ;;
  *) echo "$usage (unknown template: $template)" >&2; exit 2 ;;
esac
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
(cd "$work" && unzip -q -o "$zip")
tpl="$work/templates/$template"

# hunt branch only: the plugin branch ssh-window's one added template row, a QMP socket beside the output
# directory (templates/mavericks, the base build; the layer is left alone). Anchored on the -uuid row, and
# a template without it fails the step, so no hunt ever runs without the socket it exists to read.
if [ -n "${MVM_HUNT_QMP:-}" ] && [ "$template" = mavericks ]; then
  anchor='    ["-uuid", local.build_uuid],'
  row='    ["-qmp", "unix:${local.output_directory}-qmp.sock,server,nowait"],'
  f="$tpl/mavericks.pkr.hcl"
  [ "$(grep -cxF -- "$anchor" "$f")" = 1 ] \
    || { echo "build.sh: MVM_HUNT_QMP: $f has no single -uuid row to put the QMP row after"; exit 1; }
  awk -v a="$anchor" -v r="$row" '{ print } $0 == a { print r }' "$f" > "$f.qmp" && mv "$f.qmp" "$f"
fi

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
if ! (cd "$tpl" && env -u MVM_IMAGE_KEY -u MVM_TOKEN PACKER_LOG=1 PACKER_LOG_PATH="$work/packer-debug.log" \
      packer build -on-error=abort -var-file="$root/box.pkrvars.hcl" "${extra[@]}" .) > "$log" 2>&1; then
  echo "build.sh: building the guest ($template) with packer-plugin-macosx $pin failed; the end of packer's output:"
  tail -n 40 "$log"
  if [ -n "${MVM_LOG_DIR:-}" ]; then
    bash "$root/scripts/guest-logs.sh" "$tpl" "$work" "$MVM_LOG_DIR/$template"
    echo "build.sh: packer's logs, the serial console and the guest's own logs are kept in $MVM_LOG_DIR/$template"
    sed 's/^/build.sh:   /' "$MVM_LOG_DIR/$template/summary.txt" 2>/dev/null
  fi
  exit 1
fi

# repro branch only: a good build keeps its packer logs too, for the timeline of a good one
if [ -n "${MVM_REPRO_KEEP:-}" ] && [ -n "${MVM_LOG_DIR:-}" ]; then
  mkdir -p "$MVM_LOG_DIR/$template-ok" && cp "$work/packer-debug.log" "$log" "$MVM_LOG_DIR/$template-ok/" 2>/dev/null || true
  cp "$tpl"/output-*-install.log "$MVM_LOG_DIR/$template-ok/" 2>/dev/null || true
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
