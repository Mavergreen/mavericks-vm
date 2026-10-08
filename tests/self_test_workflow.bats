#!/usr/bin/env bats
#
# The self-test's shape: one job makes sure the shared guest exists, and only then do the
# matrix's jobs run, so they test the cache hit every consumer gets, and never race to build.

@test "the self-test's matrix waits for one warm job, which uses the Action on the shared cache" {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    run python3 - "$REPO/.github/workflows/self-test.yml" <<'PY'
import sys, yaml
jobs = yaml.safe_load(open(sys.argv[1]))["jobs"]
warm, guest = jobs.get("warm"), jobs.get("guest")
ok = warm is not None and guest is not None and guest.get("needs") == "warm"
ok = ok and "matrix" not in warm.get("strategy", {})
uses = [s for s in (warm or {}).get("steps", []) if s.get("uses") == "./"]
ok = ok and len(uses) == 1 and uses[0]["with"].get("cache-store", "auto") in ("auto", "shared")
ok = ok and warm.get("if") == guest.get("if")
sys.exit(0 if ok else 1)
PY
    [ "$status" -eq 0 ] || { echo "$output"; false; }
}

# spec: docs/superpowers/plans/2026-10-06-mavericks-vm.md Task 2 (in packer-plugin-macosx) -- the
#       space check's thresholds are the peaks measured on real runners, so every job that uses the
#       Action samples the data disk while it runs and reports the most it used
@test "every self-test job that uses the Action reports the data disk's peak use" {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    run python3 - "$REPO/.github/workflows/self-test.yml" <<'PY'
import sys, yaml
jobs = yaml.safe_load(open(sys.argv[1]))["jobs"]
bad = []
for name, job in jobs.items():
    steps = job.get("steps", [])
    for i, s in enumerate(steps):
        if s.get("uses") != "./":
            continue
        before = " ".join(str(t.get("run", "")) for t in steps[:i])
        after = [t for t in steps[i + 1:] if "peak" in str(t.get("name", "")).lower()]
        if "free.kib" not in before or not after or "always()" not in str(after[0].get("if", "")):
            bad.append(name)
print(bad)
sys.exit(1 if bad or not jobs else 0)
PY
    [ "$status" -eq 0 ] || { echo "$output"; false; }
}

# spec: every real defect found on 2026-10-07 (scp over read-only git objects, 10.9's find, the
#       empty sync: no workspace, the SSH timeout) was caught by the self-test alone, while release
#       had already moved @v1: a release now waits for the self-test of its own commit (final
#       review, I6)
@test "a release publishes, and moves @v1, only after the real-guest self-test passes" {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    run python3 - "$REPO/.github/workflows/release.yml" "$REPO/.github/workflows/self-test.yml" <<'PY'
import sys, yaml
rel = yaml.safe_load(open(sys.argv[1]))["jobs"]
st = yaml.safe_load(open(sys.argv[2]))
on = st.get(True, st.get("on"))
calls = [n for n, j in rel.items() if j.get("uses") == "./.github/workflows/self-test.yml"]
pub = rel.get("publish", {}).get("needs", [])
pub = [pub] if isinstance(pub, str) else pub
ok = len(calls) == 1 and calls[0] in pub
ok = ok and rel[calls[0]].get("secrets") == "inherit"
ok = ok and "workflow_call" in on and "push" not in on and "pull_request" in on
print(calls, pub, list(on))
sys.exit(0 if ok else 1)
PY
    [ "$status" -eq 0 ] || { echo "$output"; false; }
}

# spec: packer-plugin-macosx docs/decisions/0009, "The instruction-set levels" -- each level is
#       proven by what 10.9 reports and by the instructions that run and that fault. Under KVM a
#       level guarantees only that: on an AVX2 runner BMI runs on none and everything runs on avx,
#       so a row checks its level's promise and no more
@test "the self-test proves none, avx and avx2 by what 10.9 reports and what runs" {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    run python3 - "$REPO/.github/workflows/self-test.yml" <<'PY'
import sys, yaml
guest = yaml.safe_load(open(sys.argv[1]))["jobs"]["guest"]
rows = guest["strategy"]["matrix"]["include"]
five = "avx avx2 fma bmi1 bmi2"
want = {"none": ("", "avx avx2 fma"), "avx": ("avx", ""), "avx2": (five, "")}
bad = []
for isa, (has, faults) in want.items():
    r = [x for x in rows if x.get("cpu-isa") == isa]
    if len(r) != 1 or (r[0].get("has", ""), r[0].get("faults", "")) != (has, faults):
        bad.append("cpu-isa %s: want has=%r faults=%r, got %r" % (isa, has, faults, r))
default = [x for x in rows if "cpu-isa" not in x and "cpu-model" not in x]
if len(default) != 1 or (default[0].get("has", ""), default[0].get("faults", "")) != want["none"]:
    bad.append("want one row with neither input, proven as none: %r" % default)
uses = [s for s in guest["steps"] if s.get("uses") == "./"][0]
w, script = uses["with"], uses["with"]["run"]
if "matrix.cpu-isa" not in w.get("cpu-isa", "") or "matrix.cpu-model" not in w.get("cpu-model", ""):
    bad.append("the step does not pass cpu-isa and cpu-model from the matrix: %r" % w)
for s in ("tests/isa-probe.py", "132", "machdep.cpu.leaf7_features", "OSXSAVE", "matrix.has", "matrix.faults"):
    if s not in script:
        bad.append("the run block lacks %r" % s)
print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
    [ "$status" -eq 0 ] || { echo "$output"; false; }
}
