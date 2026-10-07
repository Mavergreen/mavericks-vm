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
