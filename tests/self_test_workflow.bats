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

# spec: a cold step builds the base and then the Aqua Transport layer (run 38166708583 peaked at
#       44 GiB with nothing to say which build used what), so each sample carries its time, and
#       the report gives the peak's time and the use by minute, to lay against the step log's
#       build.sh and layer.sh lines
@test "the data disk's samples carry their time, and the report gives the use by minute" {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    run python3 - "$REPO/.github/workflows/self-test.yml" <<'PY'
import sys, yaml
jobs = yaml.safe_load(open(sys.argv[1]))["jobs"]
bad = []
for name, job in jobs.items():
    steps = job.get("steps", [])
    samplers = [s for s in steps if "free.kib" in str(s.get("run", "")) and "while" in str(s.get("run", ""))]
    peaks = [s for s in steps if "peak" in str(s.get("name", "")).lower()]
    if not samplers:
        continue
    ok = len(samplers) == 1 and "date -u" in samplers[0]["run"]
    ok = ok and len(peaks) == 1 and " UTC" in peaks[0]["run"] and "::group::" in peaks[0]["run"]
    if not ok:
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

# spec: packer-plugin-macosx docs/decisions/0009, "The instruction-set levels" -- a guest told
#       "no AVX" never turns XSAVE on, so a none row whose 10.9 reports OSXSAVE is not none
@test "a level with no AVX fails a guest whose 10.9 has turned XSAVE on" {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    stubs="$BATS_TEST_TMPDIR/bin"; mkdir -p "$stubs"
    printf '#!/bin/sh\necho "FPU SSE4.2 XSAVE OSXSAVE VMM"; echo ""\n' > "$stubs/sysctl"
    printf '#!/bin/sh\ncase "$2" in avx|avx2|fma) kill -ILL $$ ;; esac\n' > "$stubs/python"
    chmod +x "$stubs"/*
    python3 - "$REPO/.github/workflows/self-test.yml" "$BATS_TEST_TMPDIR/none.sh" <<'PY'
import sys, yaml
guest = yaml.safe_load(open(sys.argv[1]))["jobs"]["guest"]
row = [x for x in guest["strategy"]["matrix"]["include"] if x.get("cpu-isa") == "none"][0]
script = [s for s in guest["steps"] if s.get("uses") == "./"][0]["with"]["run"]
lines = script.split("\n")
start = next(i for i, l in enumerate(lines) if l.startswith("words="))
part = "\n".join(lines[start:])
part = part.replace("${{ matrix.has }}", row.get("has", "")).replace("${{ matrix.faults }}", row.get("faults", ""))
part = part[:part.index("test \"$(pwd)\"")] if "test \"$(pwd)\"" in part else part
open(sys.argv[2], "w").write(part)
PY
    PATH="$stubs:$PATH" run sh "$BATS_TEST_TMPDIR/none.sh"
    [ "$status" -ne 0 ] || { echo "the none row passed a guest reporting OSXSAVE"; false; }
    [[ "$output" == *OSXSAVE* ]] || { echo "the failure does not name OSXSAVE: $output"; false; }
}

# spec: the Aqua Transport layer's purpose is that the guest's own /usr/bin/curl reaches modern
#       HTTPS sites, so every guest job proves it from inside the guest, and that the layer's
#       package is installed
@test "the self-test's guest run block checks outgoing TLS with /usr/bin/curl and the Aqua Transport package" {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    run python3 - "$REPO/.github/workflows/self-test.yml" <<'PY'
import sys, yaml
guest = yaml.safe_load(open(sys.argv[1]))["jobs"]["guest"]
script = [s for s in guest["steps"] if s.get("uses") == "./"][0]["with"]["run"]
bad = []
for s in ("/usr/bin/curl", "https://github.com/", "https://release-assets.githubusercontent.com/",
          "https://downloads.claude.ai/claude-code-releases/latest", "TLS to $u failed",
          "pkgutil --pkgs | grep -q '^Wowfunhappy\\.AquaTransport$'", "Aqua Transport"):
    if s not in script:
        bad.append("the run block lacks %r" % s)
print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
    [ "$status" -eq 0 ] || { echo "$output"; false; }
}

# spec: the cached guests are the base and the layer over it: the weekly eviction keeps both
#       current keys, from one fetch of the base recipe
@test "the eviction step keeps both the base's and the layer's key, from one recipe fetch" {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    run python3 - "$REPO/.github/workflows/evict.yml" <<'PY'
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["jobs"]["evict"]["steps"]
run = [s for s in steps if "key.sh" in s.get("run", "")][0]["run"]
bad = []
for s in ("key.sh --base", "key.sh --layer", "30 days ago"):
    if s not in run:
        bad.append("the run block lacks %r" % s)
if run.count("key.sh --recipe") != 1:
    bad.append("want one key.sh --recipe, got %d" % run.count("key.sh --recipe"))
if run.count("MVM_BASE_RECIPE=") < 1 or "GITHUB_ENV" in run:
    bad.append("the recipe is not handed on through MVM_BASE_RECIPE in the step's shell")
if "$keep_base" not in run or "$keep_layer" not in run or "index" not in run:
    bad.append("the jq filter does not keep both keys")
print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
    [ "$status" -eq 0 ] || { echo "$output"; false; }
}

# spec: every failure is bounded in time and names what failed -- a stalled handshake must not
#       hang the job until GitHub's six-hour default; 10.9's curl (7.30) has both options
@test "the guest's TLS fetches are time-bounded, and a failed fetch or a missing package exits 1 naming it" {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    stubs="$BATS_TEST_TMPDIR/bin"; mkdir -p "$stubs"
    python3 - "$REPO/.github/workflows/self-test.yml" "$BATS_TEST_TMPDIR/checks.sh" <<'PY'
import sys, yaml
guest = yaml.safe_load(open(sys.argv[1]))["jobs"]["guest"]
script = [s for s in guest["steps"] if s.get("uses") == "./"][0]["with"]["run"]
lines = script.split("\n")
a = next(i for i, l in enumerate(lines) if "/usr/bin/curl" in l)
b = next(i for i, l in enumerate(lines) if "AquaTransport" in l)
last = max(i for i, l in enumerate(lines) if l.strip())
assert a < b < next(i for i, l in enumerate(lines) if "roundtrip.txt" in l), "checks must come before the block's end"
open(sys.argv[2], "w").write("\n".join(lines[a:b + 1]) + "\n")
PY
    grep -q -- '--connect-timeout 20 --max-time 60' "$BATS_TEST_TMPDIR/checks.sh" || { echo "curl has no time bounds"; false; }
    grep -q -- '-sS --connect-timeout 20 --max-time 60 -o /dev/null' "$BATS_TEST_TMPDIR/checks.sh" || false
    ! grep -q -- ' -f' "$BATS_TEST_TMPDIR/checks.sh" || { echo "curl must not use -f"; false; }
    printf '#!/bin/sh\n[ -z "$CURL_FAIL" ] || [ "$CURL_FAIL" != "$(eval echo \\${$#})" ] || exit 35\nexit 0\n' > "$stubs/curl"
    printf '#!/bin/sh\n[ -z "$NO_PKG" ] || exit 0\necho Wowfunhappy.AquaTransport\n' > "$stubs/pkgutil"
    chmod +x "$stubs"/*
    # the script calls /usr/bin/curl by absolute path, so point it at the stub
    sed "s#/usr/bin/curl#$stubs/curl#" "$BATS_TEST_TMPDIR/checks.sh" > "$BATS_TEST_TMPDIR/run.sh"
    PATH="$stubs:$PATH" run bash "$BATS_TEST_TMPDIR/run.sh"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    CURL_FAIL=https://release-assets.githubusercontent.com/ PATH="$stubs:$PATH" run bash "$BATS_TEST_TMPDIR/run.sh"
    [ "$status" -eq 1 ] || { echo "$output"; false; }
    [[ "$output" == *"TLS to https://release-assets.githubusercontent.com/ failed"* ]] || { echo "$output"; false; }
    NO_PKG=1 PATH="$stubs:$PATH" run bash "$BATS_TEST_TMPDIR/run.sh"
    [ "$status" -eq 1 ] || { echo "$output"; false; }
    [[ "$output" == *AquaTransport* ]] || { echo "$output"; false; }
}

# spec: the eviction filter decides what is deleted, so it is run, not just read
@test "the eviction filter deletes old unrelated versions only: either key, no tags, and new ones stay" {
    command -v jq > /dev/null || skip "jq is not installed"
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    python3 - "$REPO/.github/workflows/evict.yml" "$BATS_TEST_TMPDIR/filter.jq" <<'PY'
import re, sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["jobs"]["evict"]["steps"]
run = [s for s in steps if "--jq" in s.get("run", "")][0]["run"]
f = re.search(r'--jq "(.*)" \\', run).group(1).replace('\\"', '"')
f = f.replace("$keep_base", "KB").replace("$keep_layer", "KL").replace("$cutoff", "2026-09-01T00:00:00Z")
open(sys.argv[2], "w").write(f)
PY
    cat > "$BATS_TEST_TMPDIR/in.json" <<'JSON'
[{"id":1,"created_at":"2026-01-01T00:00:00Z","metadata":{"container":{"tags":["KB"]}}},
 {"id":2,"created_at":"2026-01-01T00:00:00Z","metadata":{"container":{"tags":["x","KL"]}}},
 {"id":3,"created_at":"2026-01-01T00:00:00Z","metadata":{"container":{"tags":["old"]}}},
 {"id":4,"created_at":"2026-01-01T00:00:00Z","metadata":{"container":{"tags":[]}}},
 {"id":5,"created_at":"2026-01-01T00:00:00Z","metadata":{"container":{"tags":null}}},
 {"id":6,"created_at":"2026-01-01T00:00:00Z","metadata":{"container":{}}},
 {"id":7,"created_at":"2026-10-01T00:00:00Z","metadata":{"container":{"tags":["old"]}}}]
JSON
    run jq -r -f "$BATS_TEST_TMPDIR/filter.jq" "$BATS_TEST_TMPDIR/in.json"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$(echo "$output" | paste -sd' ')" = "3 4 5 6" ] || { echo "deleted: $output"; false; }
}
