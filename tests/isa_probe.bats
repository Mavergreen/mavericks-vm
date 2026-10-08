#!/usr/bin/env bats
#
# tests/isa-probe.py runs one AVX, AVX2, FMA, BMI1 or BMI2 instruction, so a
# guest proves what its CPU lets it run (the self-test's cpu-isa rows). Here,
# on the runner or a developer's host, which has all five.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    PROBE="$REPO/tests/isa-probe.py"
}

@test "each instruction runs on this host" {
    grep -qw avx2 /proc/cpuinfo || skip "this host has no AVX2"
    for n in avx avx2 fma bmi1 bmi2; do
        run python3 "$PROBE" "$n"
        [ "$status" -eq 0 ] || { echo "$n: status $status: $output"; false; }
    done
}

@test "an unknown name is a usage error" {
    run python3 "$PROBE" sse9
    [ "$status" -eq 2 ]
    [[ "$output" == *usage* ]] || false
}

@test "no name is a usage error" {
    run python3 "$PROBE"
    [ "$status" -eq 2 ]
    [[ "$output" == *usage* ]] || false
}

# platform: the guest has only Python 2.7.5 (stock 10.9), and few hosts have a python2
@test "the probe has no Python-3-only syntax, and compiles under python2 where there is one" {
    [ -f "$PROBE" ]
    if command -v python2 > /dev/null; then
        python2 -m py_compile "$PROBE"
    fi
    run grep -nE '\bf"|\bf'"'"'|print [^(]|:=|\bnonlocal\b|\basync\b|\bawait\b|def [^(]*\([^)]*:[^)]*\)|\) *->|\(\*,|, *\*,|end *= *["'"'"']' "$PROBE"
    [ "$status" -eq 1 ] || { echo "Python-3-only syntax: $output"; false; }
}
