#!/usr/bin/env bats
#
# The input contract: vmactions freebsd-vm v1.5.9's inputs, by name, meaning
# and default (docs/superpowers/specs/2026-10-06-mavericks-vm-design.md in
# packer-plugin-macosx), plus image-key, cpu-model and cpu-isa. scripts/inputs.sh
# validates and normalizes them into MVM_* lines for $GITHUB_ENV.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    GITHUB_ENV="$BATS_TEST_TMPDIR/github-env"
    : > "$GITHUB_ENV"
    export GITHUB_ENV
    # What action.yml passes for a step with every input left at its default.
    export MVM_IN_OSNAME=mavericks MVM_IN_RELEASE=10.9 MVM_IN_ARCH=x86_64 \
        MVM_IN_MEM=4096 MVM_IN_CPU=2 MVM_IN_CPU_MODEL= MVM_IN_CPU_ISA= \
        MVM_IN_SYNC=rsync MVM_IN_COPYBACK=true MVM_IN_USESH= MVM_IN_ENVS= MVM_IN_NAT= \
        MVM_IN_HAS_IMAGE_KEY=true MVM_IN_DISABLE_CACHE=false MVM_IN_CACHE_AFTER_PREPARE=false \
        MVM_IN_CACHE_AFTER_PREPARE_KEY_SUFFIX= MVM_IN_CUSTOM_SHELL_NAME=mavericks \
        MVM_IN_DATA_DIR= MVM_IN_CACHE_DIR= MVM_IN_DEBUG= MVM_IN_SYNC_TIME= MVM_IN_DEBUG_ON_ERROR= \
        MVM_IN_CACHE_STORE=auto GITHUB_REPOSITORY_OWNER=Mavergreen
}

inputs() { bash "$REPO/scripts/inputs.sh"; }
env_has() { grep -qxF "$1" "$GITHUB_ENV"; }

@test "action.yml declares every vmactions input, with vmactions' defaults or the template's" {
    run python3 - "$REPO/action.yml" <<'EOF'
import sys, yaml
want = {
    "osname": "mavericks", "prepare": None, "run": None, "release": "10.9", "arch": "x86_64",
    "envs": None, "mem": "4096", "cpu": "2", "nat": None, "usesh": None, "sync": "rsync",
    "copyback": "true", "debug": None, "data-dir": None, "cache-dir": None, "sync-time": None,
    "disable-cache": "false", "cache-after-prepare": "false",
    "cache-after-prepare-key-suffix": "", "debug-on-error": "", "vnc-password": "",
    "custom-shell-name": "mavericks", "token": "${{ github.token }}",
    "image-key": None, "cpu-model": "", "cpu-isa": "", "cache-store": "auto",
}
got = yaml.safe_load(open(sys.argv[1]))["inputs"]
bad = [f"{k}: want default {v!r}, got {got.get(k, {}).get('default')!r}" if k in got else f"{k}: missing"
       for k, v in want.items() if k not in got or got[k].get("default") != v]
extra = sorted(set(got) - set(want))
print("\n".join(bad + [f"{k}: not in the contract" for k in extra]))
sys.exit(1 if bad or extra else 0)
EOF
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    run python3 -c 'import sys,yaml; print(yaml.safe_load(open(sys.argv[1]))["outputs"]["cache-after-prepare-hit"]["value"] != "")' "$REPO/action.yml"
    [ "$output" = True ]
}

@test "the defaults normalize, and nothing about the key is written" {
    run inputs
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    env_has MVM_MEM=4096
    env_has MVM_CPU=2
    env_has 'MVM_CPU_MODEL=Penryn,vendor=GenuineIntel,+ssse3,+sse4.1,+sse4.2'
    env_has MVM_SYNC=rsync
    env_has MVM_COPYBACK=true
    env_has MVM_SHELL_NAME=mavericks
    run grep -qi 'key' "$GITHUB_ENV"
    [ "$status" -ne 0 ]
}

@test "an empty image-key fails at once, naming the fork case" {
    MVM_IN_HAS_IMAGE_KEY=false run inputs
    [ "$status" -ne 0 ]
    [[ "$output" == *"image-key"* ]] || false
    [[ "$output" == *"fork"* ]] || false
    [ ! -s "$GITHUB_ENV" ]
}

@test "only mavericks, 10.9 and x86_64 are accepted, and each refusal says what is" {
    MVM_IN_OSNAME=freebsd run inputs
    [ "$status" -ne 0 ]; [[ "$output" == *"mavericks"* ]] || false
    MVM_IN_RELEASE=10.6 run inputs
    [ "$status" -ne 0 ]; [[ "$output" == *"10.9"* ]] || false
    MVM_IN_ARCH=aarch64 run inputs
    [ "$status" -ne 0 ]; [[ "$output" == *"x86_64"* ]] || false
}

@test "sshfs and nfs are refused with their reasons; rsync, scp, tar and no are accepted" {
    MVM_IN_SYNC=sshfs run inputs
    [ "$status" -ne 0 ]; [[ "$output" == *"FUSE"* ]] || false
    MVM_IN_SYNC=nfs run inputs
    [ "$status" -ne 0 ]; [[ "$output" == *"not yet"* ]] || false
    for s in rsync scp tar no; do
        : > "$GITHUB_ENV"
        MVM_IN_SYNC=$s run inputs
        [ "$status" -eq 0 ] || { echo "$s: $output"; false; }
        env_has "MVM_SYNC=$s"
    done
}

@test "mem and cpu must be positive whole numbers" {
    for v in 0 -1 4G 1.5 ''; do
        MVM_IN_MEM=$v run inputs
        [ "$status" -ne 0 ] || { echo "mem=$v accepted"; false; }
        MVM_IN_CPU=$v run inputs
        [ "$status" -ne 0 ] || { echo "cpu=$v accepted"; false; }
    done
}

@test "usesh is accepted and ignored, as vmactions does" {
    MVM_IN_USESH=true run inputs
    [ "$status" -eq 0 ]
    run grep -q USESH "$GITHUB_ENV"
    [ "$status" -ne 0 ]
}

@test "envs takes variable names only" {
    MVM_IN_ENVS='FOO BAR_2' run inputs
    [ "$status" -eq 0 ]
    env_has 'MVM_ENVS=FOO BAR_2'
    MVM_IN_ENVS='FOO $(id)' run inputs
    [ "$status" -ne 0 ]
}

@test "nat takes vmactions' \"host\": \"guest\" lines, udp: allowed, and nothing else" {
    MVM_IN_NAT=$'"8080": "80"\n"8443": "443"\nudp:"8081": "80"' run inputs
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    env_has 'MVM_NAT=tcp:8080:80 tcp:8443:443 udp:8081:80'
    MVM_IN_NAT='"8080": "80"; rm -rf /' run inputs
    [ "$status" -ne 0 ]
}

@test "copyback and the booleans take true or false" {
    MVM_IN_COPYBACK=maybe run inputs
    [ "$status" -ne 0 ]
    MVM_IN_DISABLE_CACHE=yes run inputs
    [ "$status" -ne 0 ]
}

# GitHub's runners are AMD or Intel by chance, and on AMD 10.9 hangs unless the guest's CPU
# says GenuineIntel (packer-plugin-macosx docs/host-profile.md G2), so a cpu-model that names no
# vendor gets that one; a cpu-model that names one is the caller's choice.
@test "a cpu-model naming no vendor gets vendor=GenuineIntel after its model" {
    MVM_IN_CPU_MODEL=Nehalem run inputs
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    env_has 'MVM_CPU_MODEL=Nehalem,vendor=GenuineIntel'
    : > "$GITHUB_ENV"
    MVM_IN_CPU_MODEL='Penryn,+ssse3,+sse4.2' run inputs
    env_has 'MVM_CPU_MODEL=Penryn,vendor=GenuineIntel,+ssse3,+sse4.2'
    : > "$GITHUB_ENV"
    MVM_IN_CPU_MODEL='Haswell,vendor=AuthenticAMD' run inputs
    env_has 'MVM_CPU_MODEL=Haswell,vendor=AuthenticAMD'
}

# spec: packer-plugin-macosx docs/decisions/0009, "The instruction-set levels" -- each level is
#       a measured -cpu line, and enforce makes QEMU refuse a host that lacks a feature rather
#       than boot a guest that quietly tests as a lower level
@test "cpu-isa none, avx and avx2 are the plugin's measured lines" {
    MVM_IN_CPU_ISA=none run inputs
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    env_has 'MVM_CPU_MODEL=Penryn,vendor=GenuineIntel,+ssse3,+sse4.1,+sse4.2'
    : > "$GITHUB_ENV"
    MVM_IN_CPU_ISA=avx run inputs
    env_has 'MVM_CPU_MODEL=SandyBridge,vendor=GenuineIntel,-x2apic,-tsc-deadline,enforce'
    : > "$GITHUB_ENV"
    MVM_IN_CPU_ISA=avx2 run inputs
    env_has 'MVM_CPU_MODEL=IvyBridge,vendor=GenuineIntel,-x2apic,-tsc-deadline,+avx2,+fma,+bmi1,+bmi2,+movbe,+abm,enforce'
}

@test "neither cpu-isa nor cpu-model is none's line" {
    run inputs
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    env_has 'MVM_CPU_MODEL=Penryn,vendor=GenuineIntel,+ssse3,+sse4.1,+sse4.2'
}

@test "today's default cpu-model, passed explicitly, still works" {
    MVM_IN_CPU_MODEL='Penryn,vendor=GenuineIntel,+ssse3,+sse4.1,+sse4.2' run inputs
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    env_has 'MVM_CPU_MODEL=Penryn,vendor=GenuineIntel,+ssse3,+sse4.1,+sse4.2'
}

@test "cpu-isa and cpu-model together are refused" {
    MVM_IN_CPU_ISA=avx MVM_IN_CPU_MODEL=Nehalem run inputs
    [ "$status" -ne 0 ]
    [[ "$output" == *"set one, not both"* ]] || false
}

@test "cpu-isa takes only none, avx or avx2" {
    for v in AVX avx512 sse4 'avx '; do
        MVM_IN_CPU_ISA="$v" run inputs
        [ "$status" -ne 0 ] || { echo "cpu-isa='$v' accepted"; false; }
        [[ "$output" == *"want none, avx or avx2"* ]] || { echo "$output"; false; }
    done
}

@test "cpu-model and custom-shell-name carry no whitespace or shell metacharacters" {
    MVM_IN_CPU_MODEL='Penryn -device foo' run inputs
    [ "$status" -ne 0 ]
    MVM_IN_CUSTOM_SHELL_NAME='mav;rm' run inputs
    [ "$status" -ne 0 ]
}

@test "data-dir defaults under /mnt, cache-dir under it" {
    run inputs
    env_has MVM_DATA_DIR=/mnt/mavericks-vm
    env_has MVM_CACHE_DIR=/mnt/mavericks-vm/cache
}

@test "cache-store auto shares the registry for Mavergreen's repos, and keeps a repo's own cache for anyone else's" {
    run inputs
    env_has MVM_STORE=registry
    : > "$GITHUB_ENV"
    GITHUB_REPOSITORY_OWNER=someone-else run inputs
    [ "$status" -eq 0 ]
    env_has MVM_STORE=file
}

@test "cache-store shared and repo force the tier; anything else is refused" {
    GITHUB_REPOSITORY_OWNER=someone-else MVM_IN_CACHE_STORE=shared run inputs
    env_has MVM_STORE=registry
    : > "$GITHUB_ENV"
    MVM_IN_CACHE_STORE=repo run inputs
    env_has MVM_STORE=file
    MVM_IN_CACHE_STORE=s3 run inputs
    [ "$status" -ne 0 ]
    [[ "$output" == *"auto, shared or repo"* ]] || false
}

@test "the repo cache's encrypted image lives in data-dir" {
    MVM_IN_CACHE_STORE=repo run inputs
    env_has MVM_BLOB_DIR=/mnt/mavericks-vm/blob
}
