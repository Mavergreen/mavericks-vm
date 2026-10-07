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
