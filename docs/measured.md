# Measured

What mavericks-vm costs on GitHub's standard `ubuntu-latest` runners. Every figure comes from a real
run, with its Actions run ID. Figures that haven't been measured are marked so.

## The runners

They are AMD or Intel at random. Six CPU models have run the self-test:

| Vendor | Models seen | vCPUs | RAM | Free on `/` |
|---|---|---|---|---|
| AMD | EPYC 7763, 9V74, 9V45 | 4 | 15 GiB | 85-87 GiB |
| Intel | Xeon Platinum 8370C, 8573C; Xeon 6973P-C | 4 | 15 GiB | 85-87 GiB |

`/mnt` is on the same filesystem as `/`, and only root can write there (`scripts/dirs.sh`).

## Time

| | Measured | Run |
|---|---|---|
| A cache hit, step start to the guest answering SSH | about 3-4 min | 37653472664 |
| Boot, QEMU start to SSH | 60-67 s | every self-test |
| A cold build: fetch, build, encrypt, push | 38 min (shared registry), 39 min (repo cache) | 37653472664 |
| A consumer's whole job: openssh's pkg installed and smoke-tested | 4 min | Mavergreen/openssh 37670704996 |

## Disk

The peak use of `data-dir`'s filesystem while the step runs, sampled every 5 s (run 37653472664,
packer-plugin-macosx v0.20261005.4). `scripts/space-needed` checks for these, with a margin:

| | Peak | Checked for |
|---|---|---|
| A hit | 13-14 GiB | 20 GiB |
| A cold build | 36 GiB (shared registry), 37 GiB (repo cache) | 45 GiB |
| `cache-after-prepare`'s snapshot | **not measured**: no self-test job caches after prepare | 20 GiB |

## The cached guest

| | Size |
|---|---|
| The image, zstd -10 and age-encrypted | 6.03 GB (6.83 GB before the zero-fill, plugin v0.20261005.3) |

## What a CPU model needs

| `cpu-model` | Intel runner | AMD runner |
|---|---|---|
| Penryn, the default | boots | boots, given `vendor=GenuineIntel`, which the Action adds when a model names no vendor |
| Nehalem and later | boots, given `kvm.ignore_msrs=Y`, which the Action sets | the same |

Without `vendor=GenuineIntel`, 10.9 hangs on AMD at OpenCore's "Loading kernel cache file" (run
37524541544). Without `ignore_msrs`, Nehalem and later loop on a fault reading `MSR_FLEX_RATIO`
(0x194), on both vendors (run 37539764898; packer-plugin-macosx `docs/decisions/0009`).
