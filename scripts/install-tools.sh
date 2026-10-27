#!/bin/bash
# platform: GitHub's Linux runners only (Ubuntu's apt, bash) -- this Action runs nowhere else
#   usage: install-tools.sh | install-tools.sh --packages (prints the apt packages, one a line, for
#          the cache key of their .debs)
#          env in:  MVM_TOOLS_DIR (default $RUNNER_TEMP/mavericks-vm-tools); MVM_DEBS_DIR (the
#                   .debs actions/cache keeps for this runner image; unset, apt fetches every run);
#                   MVM_SKIP_APT and MVM_MODULES_DIR (/lib/modules) (tests); MVM_APT_TIMEOUT (180)
#                   and MVM_APT_TRIES (3), per apt step; MVM_INSTALL_TIMEOUT (600)
#          out:     QEMU, zstd and rsync from apt; hfsplus for the running kernel when it lacks it
#                   and the archive has it, and otherwise MVM_NO_HFSPLUS=<release> in $GITHUB_ENV;
#                   age, oras and packer, each its pinned release checked by sha256, on the job's PATH;
#                   debs-save=true in $GITHUB_OUTPUT when it fetched the .debs for actions/cache to keep
set -euo pipefail

# platform: what packer-plugin-macosx builds with beyond the runner image -- nasm, iasl and
#           uuid.h for OpenCore and OVMF, dmg2img and mkfs.hfsplus for the media, busybox for
#           its microVM (seen missing 2026-10-06, this repo's Actions runs 37490378092 and 37499515340)
pkgs=(qemu-system-x86 qemu-utils zstd rsync unzip nasm acpica-tools uuid-dev dmg2img hfsprogs busybox-static)
if [ "${1:-}" = --packages ]; then printf '%s\n' "${pkgs[@]}"; exit 0; fi

# spec: INGREDIENTS.md -- age, oras and packer are pinned here; QEMU, zstd and rsync are the
#       runner's apt's (untrackable)
age_version=v1.3.2
age_sha256=cbe24006683f8eb669266162894b9a522a1af52f2665fbc63a4bb032ed26ac10
oras_version=1.3.4
oras_sha256=f27adb935022d94df8dc77719c322dda592c78a0d57a6f7dcdd8d900b248c454
packer_version=1.16.1
packer_sha256=af38a9e93e4ed1b9ca68206ae969c64c300c82a3dde46a780dfa629f0867f651

dir="${MVM_TOOLS_DIR:-${RUNNER_TEMP:-/tmp}/mavericks-vm-tools}"
mkdir -p "$dir/bin"

# spec: tests/safety.bats -- apt's output went to /dev/null and nothing here had a time limit, so
#       a stalled mirror or connection hung a job for 79 minutes without a word (Mavergreen/openssh
#       Actions run 37672419741). Each step says what it is, runs under a limit, and on failure or
#       timeout shows what it printed.
limit="${MVM_INSTALL_TIMEOUT:-600}"
apt_opts=(-o DPkg::Lock::Timeout=120 -o Acquire::Retries=3 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30)
step() {  # $1 = what it is, then the command
  local what="$1" out rc=0; shift
  echo "install-tools: $what"
  out="$(timeout "$limit" "$@" 2>&1)" || rc=$?
  [ "$rc" -eq 0 ] && return 0
  if [ "$rc" -eq 124 ]; then
    echo "::error title=mavericks-vm::$what did not finish in ${limit}s; what it printed:"
  else
    echo "::error title=mavericks-vm::$what failed (exit $rc); what it printed:"
  fi
  printf '%s\n' "$out"
  exit 1
}

# spec: tests/safety.bats -- apt's install of linux-modules-extra, which every run made until 7.0
#       kernels had hfsplus without it, took 12-22 s on GitHub's runners, and on 2026-10-08 twice
#       printed nothing for the whole 600 s (runs 37833815882 and 37836734837): a stall, not slowness. So an apt step has a shorter limit and more than one
#       try, and dpkg finishes, between tries, whatever the killed attempt left half done.
apt_limit="${MVM_APT_TIMEOUT:-180}"
apt_tries="${MVM_APT_TRIES:-3}"
apt_try() {  # $1 = what it is, then apt-get's arguments; on failure, apt_why and apt_out say why
  local what="$1" rc i; shift
  echo "install-tools: $what"
  for ((i = 1; i <= apt_tries; i++)); do
    rc=0
    # spec: tests/safety.bats -- line-buffered, so what a killed apt had printed is not lost
    apt_out="$(timeout "$apt_limit" sudo stdbuf -oL -eL apt-get "${apt_opts[@]}" "$@" 2>&1)" || rc=$?
    [ "$rc" -eq 0 ] && return 0
    if [ "$rc" -eq 124 ]; then apt_why="did not finish in ${apt_limit}s"; else apt_why="failed (exit $rc)"; fi
    [ "$i" -lt "$apt_tries" ] || break
    echo "install-tools: $what $apt_why; trying again ($((i + 1)) of $apt_tries)"
    timeout "$apt_limit" sudo dpkg --configure -a > /dev/null 2>&1 || true
  done
  apt_why="$apt_why, $apt_tries times"
  return 1
}
apt_step() {
  apt_try "$@" && return 0
  echo "::error title=mavericks-vm::$1 $apt_why; what the last try printed:"
  printf '%s\n' "$apt_out"
  exit 1
}

# spec: tests/safety.bats -- the plugin's microVM loads hfsplus into the kernel it boots, and
#       takes a module it cannot find to be built in, so without it the microVM fails later,
#       mounting the installer (Actions runs 37507097828, 37508429892). Ubuntu's Azure kernels
#       through 6.17 keep hfsplus in linux-modules-extra-<release>, which the runner image does
#       not install; 7.0's have no such package, and hfsplus is in linux-modules-<release>, which
#       every kernel has (ubuntu24/20261018.339 asked for linux-modules-extra-7.0.0-1017-azure,
#       which does not exist: Mavergreen/longboat Actions run 39311778407). So what is installed
#       follows from what the running kernel lacks, and the log says which.
mods="${MVM_MODULES_DIR:-/lib/modules}"
kernel_with_hfsplus() {  # for the running release $rel: hfsplus a module in its tree, or built in
  if [ -n "$(find -H "$mods/$rel" -name 'hfsplus.ko*' -print -quit 2> /dev/null)" ] \
    || grep -qs '/hfsplus\.ko$' "$mods/$rel/modules.builtin"; then
    echo "install-tools: the running kernel, $rel, has hfsplus: no kernel package to install"
    return
  fi
  # spec: tests/safety.bats -- this step runs before the run knows whether it builds the base
  #       image, the only build that needs hfsplus (for its installer media), and says so
  if apt-cache show "linux-modules-extra-$rel" > /dev/null 2>&1; then
    echo "install-tools: the running kernel, $rel, has no hfsplus; installing linux-modules-extra-$rel, which has it, before this run knows whether it builds the base image"
    # spec: tests/safety.bats -- the install stalled 3 times on 2026-10-26 (Mavergreen/longboat
    #       Actions run 40250148980) in a run with a cached base image, which needs no hfsplus;
    #       so a failed install, like a missing package, leaves main.sh to stop only a base build
    apt_try "apt-get install of linux-modules-extra-$rel" \
      install -y -q --no-install-recommends "linux-modules-extra-$rel" && return
    echo "::warning title=mavericks-vm::apt-get install of linux-modules-extra-$rel $apt_why, so the running kernel has no hfsplus module: building the base image here would fail, so this run stops if it must build one; what the last try printed:"
    printf '%s\n' "$apt_out"
    echo "MVM_NO_HFSPLUS=$rel" >> "${GITHUB_ENV:-/dev/null}"
    return
  fi
  # spec: tests/main.bats -- nothing else here can supply it: the pinned plugin boots only the
  #       running kernel (packer-plugin-macosx boots another installed one, which this step could
  #       then unpack, from the release with privops' chooseRelease, once this repo pins it). So
  #       the run goes on, and main.sh stops it if, and only if, it must build the base image.
  echo "::warning title=mavericks-vm::the running kernel, $rel, has no hfsplus module, and the archive has no linux-modules-extra-$rel: building the base image here would fail, so this run stops if it must build one"
  echo "MVM_NO_HFSPLUS=$rel" >> "${GITHUB_ENV:-/dev/null}"
}

# spec: tests/safety.bats -- on 2026-10-26 one runner in six got the archive's .debs at ~70 kB/s
#       while the others got 15-37 MB/s (the slow ones' index fetch ran at ~9 MB/s), so the 20 MB
#       install ran past apt_limit three times running, and apt's own timeouts never fire on a
#       trickle (this repo's self-test run 40382445949, apt-probe run 40425490693). So the .debs
#       this runner image lacks are kept in actions/cache, keyed by the image and this package list
#       (action.yml): a hit installs them with no mirror at all; a miss fetches them once, into
#       MVM_DEBS_DIR, for the action to save. -q, not -qq: a timeout then shows the download it was on.
debs="${MVM_DEBS_DIR:-}"
# spec: tests/safety.bats -- offline means apt has no sources at all, so it can only use the files
#       it is given: measured on the runners (apt-probe run of c17f32d), --no-download refuses local
#       .debs ("Unable to fetch some archives"), and a plain install of them fetches all 20 MB again
debs_install() {  # the .debs in $debs, offline; on failure, apt_why and apt_out say why
  local f=("$debs"/*.deb)
  [ -e "${f[0]}" ] || return 0
  apt_try "apt-get install of QEMU and the plugin's build tools" \
    install -y -q --no-install-recommends -o Dir::Etc::SourceList=/dev/null -o Dir::Etc::SourceParts=/nonexistent "${f[@]}"
}
from_archive() {
  apt_step "apt-get update" update -qq
  if [ -z "$debs" ]; then
    apt_step "apt-get install of QEMU and the plugin's build tools" \
      install -y -q --no-install-recommends "${pkgs[@]}"
    return
  fi
  echo "install-tools: no apt packages cached for this runner image: fetching them from the archive, for actions/cache to keep"
  rm -rf "$debs" && mkdir -p "$debs/partial"
  apt_step "apt-get download of QEMU and the plugin's build tools" \
    install -y -q --no-install-recommends --download-only -o "Dir::Cache::Archives=$debs" "${pkgs[@]}"
  # spec: tests/safety.bats -- apt's lock is root's alone, and actions/cache could not read it
  sudo rm -rf "$debs/lock" "$debs/partial"
  if ! debs_install; then
    echo "::error title=mavericks-vm::apt-get install of QEMU and the plugin's build tools $apt_why; what the last try printed:"
    printf '%s\n' "$apt_out"
    exit 1
  fi
  printf '%s\n' "${pkgs[@]}" > "$debs/packages"
  echo "debs-save=true" >> "${GITHUB_OUTPUT:-/dev/null}"
}

if [ -z "${MVM_SKIP_APT:-}" ]; then
  if [ -n "$debs" ] && [ "$(cat "$debs/packages" 2> /dev/null)" = "$(printf '%s\n' "${pkgs[@]}")" ]; then
    n="$(find "$debs" -maxdepth 1 -name '*.deb' | wc -l)"
    echo "install-tools: installing the $n apt packages cached for this runner image, with no download"
    if ! debs_install; then
      echo "::warning title=mavericks-vm::the apt packages cached for this runner image did not install offline ($apt_why), so they are fetched from the archive again; what apt printed:"
      printf '%s\n' "$apt_out"
      from_archive
    fi
  else
    from_archive
  fi
  # platform: GitHub's runner user is not in the kvm group; the device is root-only by default
  sudo chmod 666 /dev/kvm
  # platform: a cpu-model of Nehalem or later makes 10.9's kernel read MSR_FLEX_RATIO (0x194) at
  #           boot, which KVM emulates on neither vendor: the read faults and the guest resets
  #           in a loop. Ignored, it reads 0 and the guest boots (measured 2026-10-06, Actions run
  #           37539764898 and packer-plugin-macosx docs/decisions/0009). The default Penryn never
  #           reads it; the runner is disposable, so this costs nothing else
  echo Y | sudo tee /sys/module/kvm/parameters/ignore_msrs > /dev/null
  # platform: the plugin's media microVM boots the running kernel (the pinned plugin, always),
  #           which Ubuntu leaves readable by root alone (0600 on the 2026-10-06 runner image)
  rel="$(uname -r)"
  sudo chmod 644 "/boot/vmlinuz-$rel"
  kernel_with_hfsplus
fi

fetch() {  # $1 = url, $2 = sha256, $3 = file
  step "download of $3" curl -fsSL --connect-timeout 20 --max-time 300 --retry 3 -o "$dir/$3" "$1"
  got="$(sha256sum "$dir/$3" | cut -d' ' -f1)"
  [ "$got" = "$2" ] || { echo "::error title=mavericks-vm::$3 has sha256 $got, not the pinned $2"; exit 1; }
}
fetch "https://github.com/FiloSottile/age/releases/download/$age_version/age-$age_version-linux-amd64.tar.gz" "$age_sha256" age.tgz
tar -xzf "$dir/age.tgz" -C "$dir" && cp "$dir/age/age" "$dir/age/age-keygen" "$dir/bin/"
fetch "https://github.com/oras-project/oras/releases/download/v$oras_version/oras_${oras_version}_linux_amd64.tar.gz" "$oras_sha256" oras.tgz
tar -xzf "$dir/oras.tgz" -C "$dir/bin" oras
fetch "https://releases.hashicorp.com/packer/$packer_version/packer_${packer_version}_linux_amd64.zip" "$packer_sha256" packer.zip
unzip -q -o "$dir/packer.zip" -d "$dir/bin"
echo "$dir/bin" >> "${GITHUB_PATH:-/dev/null}"
