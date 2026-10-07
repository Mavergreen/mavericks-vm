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
