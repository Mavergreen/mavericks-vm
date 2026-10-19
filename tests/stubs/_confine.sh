# spec: tests/stubs_safety.bats -- sourced by every stub that writes a file it is told to. The
#       stubs run on this machine: a draft's fake dpkg-deb, told by a mutated script to unpack onto
#       /, wrote into its /boot and /lib/modules (packer-plugin-macosx's kskew review, 2026-10-19). A path
#       outside the test's own tmp dir (STUB_ROOT, or BATS_TEST_TMPDIR) is refused, by name,
#       before anything is written, and with neither set every write is. STUB_GUEST_SCRATCH, a
#       path prefix, admits the stand-in guest's own scratch too: its /tmp is this machine's.
confine() {  # $@ = the paths the stub is about to write
  local root p r
  root="${STUB_ROOT:-${BATS_TEST_TMPDIR:-}}"
  if [ -z "$root" ]; then
    echo "stub $(basename "$0"): refusing to write $*: no STUB_ROOT or BATS_TEST_TMPDIR to confine it to" >&2
    exit 97
  fi
  root="$(realpath -m -- "$root")"
  for p in "$@"; do
    r="$(realpath -m -- "$p" 2> /dev/null)/"
    case "$r" in
      "$root"/*) ;;
      "${STUB_GUEST_SCRATCH:-//}"*) ;;  # unset, "//": realpath never prints a path that starts so
      *) echo "stub $(basename "$0"): refusing to write $p, outside $root" >&2; exit 97 ;;
    esac
  done
}
