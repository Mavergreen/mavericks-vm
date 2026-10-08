# Mavericks GitHub Actions runner

From a GitHub Actions workflow, run code and tests on Mac OS X 10.9 Mavericks.

Modeled after [vmactions](https://github.com/vmactions), with an additional constraint:
because the OS is not open source, the VM image must not be shared publicly.

## How to use

In your non-Mavergreen repo:

```sh
age-keygen | grep '^AGE-SECRET-KEY-1' | { read -r k && printf '%s' "$k" | gh secret set MAVERICKS_VM_KEY; }
```

(To change the key that keeps your VM image private, just run it again.)

In your repo's workflow:

```yaml
jobs:
  run-stuff-on-mavericks:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: Mavergreen/mavericks-vm@v1
        with:
          image-key: ${{ secrets.MAVERICKS_VM_KEY }}
          run: |
            sw_vers
            sh tests/run-on-target.sh
```

It takes a while to
[build the VM image](https://github.com/Mavergreen/packer-plugin-macosx).
Once cached, it boots much more quickly.
The cache expires after a week without any runs.

For repos under the Mavergreen org, `MAVERICKS_VM_KEY` is an org-level secret and the cache is shared.
For each Mavergreen repo, in the
[web UI](https://github.com/orgs/Mavergreen/packages/container/mavericks-vm-images/settings),
enable write access: Manage Actions access -> Add repository -> change role Read to Write.
In each repo's workflow, also specify the job's permissions:

```yaml
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
```

## Inputs

As with vmactions:

| Input | Default | |
|---|---|---|
| `osname` | `mavericks` | Only `mavericks` |
| `release` | `10.9` | Only `10.9` |
| `arch` | `x86_64` | Only `x86_64` |
| `run` | | Commands run in the guest, with `sh -e` |
| `prepare` | | Commands run before `run` |
| `envs` | | Names of environment variables to pass in, space-separated |
| `sync` | `rsync` | How the workspace gets in and back: `rsync`, `scp`, `tar` or `no` |
| `copyback` | `true` | Copy the workspace back after `run` |
| `mem` | `4096` | Guest memory, in MiB |
| `cpu` | `2` | Guest CPU cores |
| `nat` | | Port forwards, as `"host": "guest"` lines |
| `cache-after-prepare` | `false` | Cache the guest again after `prepare`, so later runs with the same `prepare` and the same guest CPU skip it |
| `cache-after-prepare-key-suffix` | | Change it to run `prepare` again and cache the result anew |
| `custom-shell-name` | `mavericks` | Later steps can use `shell: mavericks {0}` |
| `debug-on-error` | | On failure, print the guest's `system.log` |
| `disable-cache` | `false` | Always build the guest; never use the cache |
| `sync-time` | | Set the guest's clock from the runner's before `run` |
| `data-dir` | `/mnt/mavericks-vm` | Where the guest's images live on the runner |
| `cache-dir` | under `data-dir` | Where the build's downloads are cached on the runner |
| `debug` | | Print debug output |
| `usesh` | | Accepted and ignored: `prepare` and `run` always use `sh` |
| `vnc-password` | | Accepted and ignored: there is no screen |
| `token` | `${{ github.token }}` | Pulls and pushes Mavergreen's shared cache; needs `packages: write` |

Plus four more:

| Input | | |
|---|---|---|
| `image-key` | required | Your key, the secret `MAVERICKS_VM_KEY`: it encrypts and decrypts your cached guest |
| `cpu-isa` | `none` | The guest CPU by the instructions it has: `none` (no AVX), `avx` (Sandy Bridge: AVX, not AVX2, FMA or BMI) or `avx2` (AVX2, FMA, BMI1 and BMI2 too). Under KVM a level is what the guest is *told*: the instructions above it still run on the runner's CPU, except that `none` makes the AVX family fault. `avx` and `avx2` make QEMU refuse a runner that lacks one of their instructions; `none`, the default line unchanged, does not. Not with `cpu-model` |
| `cpu-model` | | The guest CPU, as QEMU's `-cpu`, instead of `cpu-isa`. Without a `vendor=`, it gets `vendor=GenuineIntel`: on GitHub's AMD runners, 10.9 hangs without it |
| `cache-store` | `auto` | `repo` (your repo's own cache), `shared` (Mavergreen's), or `auto` |

After the step, `ssh mavericks` reaches the guest from later steps.

## What it can't do

- `sync: sshfs` or `nfs`
- VNC
- run on PRs from forks (don't have the secret, can't decrypt the image)
