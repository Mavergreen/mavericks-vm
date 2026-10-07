#!/bin/bash
# platform: GitHub's Linux runners only (Ubuntu's apt, bash) -- this Action runs nowhere else
#   usage: install-tools.sh
#          env in:  MVM_TOOLS_DIR (default $RUNNER_TEMP/mavericks-vm-tools); MVM_SKIP_APT (tests)
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

if [ -z "${MVM_SKIP_APT:-}" ]; then
  sudo apt-get update -qq
  # platform: what packer-plugin-macosx builds with beyond the runner image -- nasm, iasl and
  #           uuid.h for OpenCore and OVMF, dmg2img and mkfs.hfsplus for the media, busybox for
  #           its microVM (seen missing 2026-10-06, this repo's Actions runs 37490378092 and 37499515340)
  sudo apt-get install -y -qq --no-install-recommends qemu-system-x86 qemu-utils zstd rsync unzip \
    nasm acpica-tools uuid-dev dmg2img hfsprogs busybox-static > /dev/null
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
  sudo apt-get install -y -qq --no-install-recommends "linux-modules-extra-$(uname -r)" > /dev/null
fi

fetch() {  # $1 = url, $2 = sha256, $3 = file
  curl -fsSL --retry 3 -o "$dir/$3" "$1"
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
