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
| A cache hit of the base and the layer, step start to the guest answering SSH | about 4 min | 38174599184 |
| Boot, QEMU start to SSH | 51-54 s (60-67 s before the layer) | every self-test |
| A cold build: the base (fetch, build, encrypt, push, 38 min), then the layer over it (14 min) | 53 min (shared registry), 54 min (repo cache) | 38166708583 |
| A layer-only build: pull the cached base, build and push the layer | 15 min (shared registry), 14 min (repo cache) | 38175442692 |
| A consumer's whole job: openssh's pkg installed and smoke-tested | 4 min | Mavergreen/openssh 37670704996 |

## Disk

The peak use of `data-dir`'s filesystem while the step runs, sampled every 5 s with its time, on
2026-10-11 with packer-plugin-macosx v0.20261005.6 and .7. `scripts/space-needed` checks for these,
with a margin, before each step starts:

| | Peak | Checked for |
|---|---|---|
| A hit | 14 GiB (shared registry, run 38174599184); 20 GiB with the repo cache, whose ~6 GiB restore lands before the check | 20 GiB |
| A cold build: the base and then the layer over it (a new base is always a new layer, which is bound to it) | 44 GiB (shared registry), 49 GiB (repo cache), run 38166708583 | 55 GiB |
| A layer build over a pulled base | 12-13 GiB more than the base already took: 30 GiB in all (shared registry), 36 GiB (repo cache), run 38175442692 | 20 GiB |
| `cache-after-prepare`'s snapshot | **not measured**: no self-test job caches after prepare | 20 GiB |

## The cached guest

| | Size |
|---|---|
| The base image, zstd -10 and age-encrypted | 6.03 GB (6.83 GB before the zero-fill, plugin v0.20261005.3) |
| The Aqua Transport layer, a qcow2 delta over the base, the same | 52 MB (run 38166708583) |

## What a CPU model needs

| `cpu-model` | Intel runner | AMD runner |
|---|---|---|
| Penryn, the default | boots | boots, given `vendor=GenuineIntel`, which the Action adds when a model names no vendor |
| Nehalem and later | boots, given `kvm.ignore_msrs=Y`, which the Action sets | the same |

Without `vendor=GenuineIntel`, 10.9 hangs on AMD at OpenCore's "Loading kernel cache file" (run
37524541544). Without `ignore_msrs`, Nehalem and later loop on a fault reading `MSR_FLEX_RATIO`
(0x194), on both vendors (run 37539764898; packer-plugin-macosx `docs/decisions/0009`).

## What each `cpu-isa` level proves

Each level was proven on 2026-10-08 by what 10.9 reports and by the
instructions that run and that fault (`tests/isa-probe.py`). Every job
below passed.

| `cpu-isa` | Intel runner | AMD runner |
|---|---|---|
| `none` (and the default) | Xeon Platinum 8370C: run 37836734837 attempt 3 | release run 37833815882; run 37836734837 |
| `avx` | Xeon Platinum 8370C: run 37836734837 attempt 3, job 113525776093 | EPYC 9V74: release run 37833815882; EPYC 7763 and 9V74: run 37836734837 attempts 1, 2, 4 and 6 |
| `avx2` | Xeon Platinum 8573C: run 37836734837 attempt 3, job 113525776062 | EPYC 7763: release run 37833815882 (second attempt); EPYC 7763 and 9V45: run 37836734837 attempts 1, 2, 4 and 6 |

Under KVM a level is what the guest is *told*. On these runners, which
all have AVX2:
- `avx` runs AVX2, FMA and BMI too.
- `none` runs BMI, but faults on the AVX family.

The self-test asserts only what each level guarantees. Two jobs that day
failed before any guest booted, both because `apt-get
install` of the runner's `linux-modules-extra` printed nothing for 600 s
(run 37833815882 attempt 1; run 37836734837 attempt 5). That step takes 12-22 s in every other
job that day, so `install-tools.sh` now gives an apt step 180 s and three tries.
