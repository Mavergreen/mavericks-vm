#!/bin/bash
# platform: GitHub's Linux runners only (Ubuntu's apt, bash) -- this Action runs nowhere else
#   usage: install-tools.sh
#          env in:  MVM_TOOLS_DIR (default $RUNNER_TEMP/mavericks-vm-tools); MVM_SKIP_APT (tests);
#                   MVM_APT_TIMEOUT (180) and MVM_APT_TRIES (3), per apt step; MVM_INSTALL_TIMEOUT (600)
#          out:     QEMU, zstd and rsync from apt; age, oras and packer, each its pinned release
#                   checked by sha256, on the job's PATH
set -euo pipefail

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

# spec: tests/safety.bats -- apt's install of linux-modules-extra takes 12-22 s on GitHub's runners,
#       and on 2026-10-08 twice printed nothing for the whole 600 s (runs 37833815882 and
#       37836734837): a stall, not slowness. So an apt step has a shorter limit and more than one
#       try, and dpkg finishes, between tries, whatever the killed attempt left half done.
apt_limit="${MVM_APT_TIMEOUT:-180}"
apt_tries="${MVM_APT_TRIES:-3}"
apt_step() {  # $1 = what it is, then apt-get's arguments
  local what="$1" out rc i why; shift
  echo "install-tools: $what"
  for ((i = 1; i <= apt_tries; i++)); do
    rc=0
    out="$(timeout "$apt_limit" sudo apt-get "${apt_opts[@]}" "$@" 2>&1)" || rc=$?
    [ "$rc" -eq 0 ] && return 0
    if [ "$rc" -eq 124 ]; then why="did not finish in ${apt_limit}s"; else why="failed (exit $rc)"; fi
    [ "$i" -lt "$apt_tries" ] || break
    echo "install-tools: $what $why; trying again ($((i + 1)) of $apt_tries)"
    timeout "$apt_limit" sudo dpkg --configure -a > /dev/null 2>&1 || true
  done
  echo "::error title=mavericks-vm::$what $why, $apt_tries times; what the last try printed:"
  printf '%s\n' "$out"
  exit 1
}

if [ -z "${MVM_SKIP_APT:-}" ]; then
  apt_step "apt-get update" update -qq
  # platform: what packer-plugin-macosx builds with beyond the runner image -- nasm, iasl and
  #           uuid.h for OpenCore and OVMF, dmg2img and mkfs.hfsplus for the media, busybox for
  #           its microVM (seen missing 2026-10-06, this repo's Actions runs 37490378092 and 37499515340)
  apt_step "apt-get install of QEMU and the plugin's build tools" \
    install -y -qq --no-install-recommends qemu-system-x86 qemu-utils \
    zstd rsync unzip nasm acpica-tools uuid-dev dmg2img hfsprogs busybox-static
  # platform: GitHub's runner user is not in the kvm group; the device is root-only by default
  sudo chmod 666 /dev/kvm
  # platform: a cpu-model of Nehalem or later makes 10.9's kernel read MSR_FLEX_RATIO (0x194) at
  #           boot, which KVM emulates on neither vendor: the read faults and the guest resets
  #           in a loop. Ignored, it reads 0 and the guest boots (measured 2026-10-06, Actions run
  #           37539764898 and packer-plugin-macosx docs/decisions/0009). The default Penryn never
  #           reads it; the runner is disposable, so this costs nothing else
  echo Y | sudo tee /sys/module/kvm/parameters/ignore_msrs > /dev/null
  # platform: the plugin's media microVM boots the runner's own kernel, which Ubuntu leaves
  #           readable by root alone (0600 on the 2026-10-06 runner image)
  sudo chmod 644 "/boot/vmlinuz-$(uname -r)"
  # platform: and loads hfsplus into it, which Ubuntu's Azure kernel ships only in its extra
  #           modules; the plugin takes a module it cannot find to be built in, so without these
  #           its microVM fails later, mounting the installer (Actions runs 37507097828, 37508429892)
  apt_step "apt-get install of linux-modules-extra-$(uname -r)" \
    install -y -qq --no-install-recommends "linux-modules-extra-$(uname -r)"
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
