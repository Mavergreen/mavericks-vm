#!/usr/bin/env bats
#
# The guest's /bin/sh is Apple's bash 3.2.53. Under sh -e it does not stop when a ( … )
# subshell, a [[ ]] or a (( )) fails and nothing checks its status (MEASURED 2026-11-24 on a
# 10.9.5 guest), so a step whose test failed passed: Mavergreen/swift's release.yml did, three
# runs running. scripts/subshell-check.sh refuses such text on the runner, before the boot.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

check() { printf '%s\n' "$1" | bash "$REPO/scripts/subshell-check.sh" run; }
refused() {
    run check "$1"
    [ "$status" -eq 1 ] || { echo "not refused: $1"; echo "$output"; false; }
}
passed() {
    run check "$1"
    [ "$status" -eq 0 ] || { echo "refused: $1"; echo "$output"; false; }
}

@test "a subshell whose status nothing checks is refused, wherever 10.9's sh -e lets it pass" {
    refused $'( false )\ntrue'
    refused $'( cd d && false )\ntrue'
    refused $'( false ) > out.txt 2>&1\ntrue'
    refused $'make && ( cd t && make check )\ntrue'
    refused $'make || ( echo no; exit 1 )\ntrue'
    refused $'true | ( false )\ntrue'
    refused $'if [ -d t ]; then ( false ); fi\ntrue'
    refused $'for d in a b; do ( cd "$d" && make ); done\ntrue'
    refused $'case $x in a) ( false ) ;; *) true ;; esac\ntrue'
    refused $'{ ( false ); true; }\ntrue'
    refused $'f() { ( false ); true; }\nf'
    refused $'while read l; do\n  ( false )\n  echo "$l"\ndone < list\ntrue'
}

@test "a bare [[ ]] or (( )) is refused too" {
    refused $'[[ $a = b ]]\ntrue'
    refused $'(( n > 0 ))\ntrue'
    refused $'if true; then\n  [[ -f x ]]\n  true\nfi'
}

@test "a subshell spanning lines is followed to its closing paren" {
    refused $'( cd gate &&\n  sh run.sh --gate )\ntrue'
    passed $'( cd gate &&\n  sh run.sh --gate ) || exit 1\ntrue'
    passed $'(\n  cd gate\n  sh run.sh --gate\n) || exit 1\ntrue'
}

@test "what stops on 10.9, or is checked, passes" {
    passed $'{ false; }\ntrue'
    passed $'make && false\ntrue'
    passed $'x=$(false)\ntrue'
    passed $'x=$( (false) )\ntrue'
    passed $'( false ) || exit 1\ntrue'
    passed $'rc=0; ( false ) || rc=$?\n[ "$rc" -eq 0 ]'
    passed $'( false ) 2>/dev/null || exit 1\ntrue'
    passed $'( a ) && b\ntrue'
    passed $'( a ) | tee log\ntrue'
    passed $'( sleep 9 ) &\ntrue'
    passed $'! ( false )\ntrue'
    passed $'if ( false ); then :; fi\ntrue'
    passed $'if [ -d x ] && ( cd x && false ); then :; elif ( false ); then :; fi\ntrue'
    passed $'while ( false ); do :; done\ntrue'
    passed $'until [[ -f x ]]; do sleep 1; done\ntrue'
    passed $'[[ a = b ]] || exit 1\ntrue'
    passed $'(( n > 0 )) || n=1\ntrue'
}

@test "a subshell or [[ ]] that is a function's or the text's last command sets that status, so it passes" {
    passed $'f() { true; ( false ); }\nf'
    passed $'f() { [[ a = b ]]; }\nf'
    passed $'function g { ( false ); }\ng'
    passed $'f() ( false )\nf'
    passed $'true\n( false )'
}

@test "no false alarm from substitutions, arithmetic, case patterns, function definitions or arrays" {
    passed $'x=$(( 1 + 2 ))\necho $x'
    passed $'echo "$( (cd x; ls) )"\ntrue'
    passed $'x=`(false)`\ntrue'
    passed $'for ((i = 0; i < 2; i++)); do :; done\ntrue'
    passed $'case $x in (a) echo a ;; b|c) echo bc ;; *) ;; esac\ntrue'
    passed $'case $x in\n  a) echo a ;;\n  *) echo other\nesac\ntrue'
    passed $'f() {\n  true\n}\nf'
    passed $'a=(1 2)\ntrue'
    passed $'diff <(sort a) <(sort b)\ntrue'
    passed $'echo a\\(b\ntrue'
}

@test "no false alarm from quotes, comments or heredocs" {
    passed $'echo "( false )"\ntrue'
    passed $'echo \'( false )\'\ntrue'
    passed $'# ( false )\ntrue'
    passed $'echo hi # ( false )\ntrue'
    passed $'cat <<EOF\n( false )\n[[ a ]]\nEOF\ntrue'
    passed $'cat > f <<-"END"\n\t( false )\n\tEND\ntrue'
    passed $'cat <<\'X\' | sh\n( false )\nX\ntrue'
}

@test "the error names the text, the lines and the fix" {
    run check $'true\n( cd gate &&\n  sh run.sh --gate )\necho done'
    [ "$status" -eq 1 ]
    [[ "${lines[0]}" == '::error title=mavericks-vm::run, lines 2-3: a ( … ) subshell whose status nothing checks.'* ]] || false
    [[ "${lines[0]}" == *'bash 3.2.53'* ]] || false
    [[ "${lines[0]}" == *'|| exit 1'* ]] || false
    [ "${lines[1]}" = '     2 | ( cd gate &&' ]
    [ "${lines[2]}" = '     3 |   sh run.sh --gate )' ]
}

@test "each finding is named, and the text with none prints nothing" {
    run check $'( a )\ntrue\n[[ b ]]\ntrue'
    [ "$status" -eq 1 ]
    [ "$(printf '%s\n' "$output" | grep -c '^::error')" -eq 2 ]
    [[ "$output" == *'run, line 1:'* ]] || false
    [[ "$output" == *'run, line 3:'* ]] || false
    run check 'true'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "prepare and run are checked before anything is pulled or booted" {
    S="$BATS_TEST_TMPDIR/scripts"; mkdir -p "$S"
    cp "$REPO/scripts/main.sh" "$REPO/scripts/subshell-check.sh" "$S/"
    export CALLS="$BATS_TEST_TMPDIR/calls"; : > "$CALLS"
    for f in key.sh image.sh build.sh layer.sh boot.sh sync.sh run.sh shell-wrapper.sh space.sh snapshot.sh aqua.sh; do
        printf '#!/bin/bash\necho "%s $*" >> "$CALLS"\n' "$f" > "$S/$f"
    done
    export PATH="$REPO/tests/stubs:$PATH" STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
    export MVM_IMAGE_KEY='AGE-SECRET-KEY-1SUBSHELLTEST' MVM_DATA_DIR="$BATS_TEST_TMPDIR/data" GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out"
    MVM_PREPARE=$'( false )\ntrue' MVM_RUN=$'[[ a ]]\ntrue' run bash "$S/main.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *'::error title=mavericks-vm::prepare, line 1:'* ]] || false
    [[ "$output" == *'::error title=mavericks-vm::run, line 1:'* ]] || false
    [ ! -s "$CALLS" ] || { cat "$CALLS"; false; }
}

@test "a custom-shell step's script is checked before it reaches the guest" {
    export PATH="$REPO/tests/stubs:$PATH" STUB_LOG="$BATS_TEST_TMPDIR/stub.log" STUB_SSH_UP=1
    : > "$STUB_LOG"
    export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME/.ssh"; : > "$HOME/.ssh/config"
    export GITHUB_WORKSPACE="$BATS_TEST_TMPDIR/work" MVM_ENVS=; mkdir -p "$GITHUB_WORKSPACE"
    printf '( false )\necho after > after.txt\n' > "$BATS_TEST_TMPDIR/step.sh"
    run bash "$REPO/scripts/run.sh" "$BATS_TEST_TMPDIR/step.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *'::error title=mavericks-vm::step, line 1:'* ]] || false
    run grep '^ssh' "$STUB_LOG"
    [ "$status" -ne 0 ]
}
