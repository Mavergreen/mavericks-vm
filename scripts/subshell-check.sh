#!/bin/bash
# platform: GitHub's Linux runners only (bash) -- this Action runs nowhere else
#   usage: subshell-check.sh <name>
#          in:   a step's prepare or run text on stdin; <name> names it in the messages
#          out:  an ::error for each failure 10.9's sh -e would let pass, naming its line and the
#                fix; exit 1 if there is one, else 0
# spec: tests/subshell_check.bats -- the guest's /bin/sh is Apple's bash 3.2.53, which does not
#       stop under -e when a ( … ) subshell, a [[ ]] or a (( )) fails and nothing checks its
#       status, and an ERR trap misses it too (MEASURED 2026-11-24 on a 10.9.5 guest); bash 4.0
#       fixed subshells and 4.1 [[ ]] and (( )), so only the guest shows it. A handler is any ||,
#       an if, while or until condition, a ! or the left side of && or of a pipe; a subshell that
#       is a function's or the text's last command sets that status itself, so it stops too.
set -uo pipefail
export LC_ALL=C

name="${1:?usage: subshell-check.sh <name>}"
src="$(cat; printf x)"; src="${src%x}"
n=${#src}
nl=$'\n'

tk=() tt=() tl=()
line=1 at=0 i=0
emit() {
  local seg="${src:at:$3-at}"
  seg="${seg//[!$nl]/}"; line=$((line + ${#seg})); at=$3
  tk+=("$1"); tt+=("$2"); tl+=("$line")
}

skip_squote() {
  local rest="${src:i+1}" head
  head="${rest%%\'*}"
  if [ "$head" = "$rest" ]; then i=$n; else i=$((i + 2 + ${#head})); fi
}
skip_bq() {
  local c
  i=$((i + 1))
  while ((i < n)); do
    c="${src:i:1}"
    case "$c" in
      \\) i=$((i + 2)) ;;
      \`) i=$((i + 1)); return ;;
      *) i=$((i + 1)) ;;
    esac
  done
}
skip_group() {
  local open="$1" close="$2" d=0 c
  while ((i < n)); do
    c="${src:i:1}"
    case "$c" in
      \\) i=$((i + 2)); continue ;;
      \') skip_squote; continue ;;
      \") skip_dquote; continue ;;
      \`) skip_bq; continue ;;
    esac
    if [ "$c" = "$open" ]; then d=$((d + 1))
    elif [ "$c" = "$close" ]; then
      d=$((d - 1))
      if ((d == 0)); then i=$((i + 1)); return; fi
    fi
    i=$((i + 1))
  done
}
skip_dquote() {
  local c
  i=$((i + 1))
  while ((i < n)); do
    c="${src:i:1}"
    case "$c" in
      \\) i=$((i + 2)) ;;
      \") i=$((i + 1)); return ;;
      \`) skip_bq ;;
      \$)
        case "${src:i+1:1}" in
          \() i=$((i + 1)); skip_group '(' ')' ;;
          \{) i=$((i + 1)); skip_group '{' '}' ;;
          *) i=$((i + 1)) ;;
        esac ;;
      *) i=$((i + 1)) ;;
    esac
  done
}

heredocs=() want_delim=""
skip_heredocs() {
  local h dash delim rest l
  for h in "${heredocs[@]}"; do
    dash="${h%%:*}" delim="${h#*:}"
    while ((i < n)); do
      rest="${src:i}"; l="${rest%%"$nl"*}"
      if [ "$l" = "$rest" ]; then i=$n; else i=$((i + ${#l} + 1)); fi
      [ "$dash" = - ] && l="${l#"${l%%[!$'\t']*}"}"
      [ "$l" != "$delim" ] || break
    done
  done
  heredocs=()
}

word() {
  local s=$i c w
  case "${src:i:2}" in '<('|'>(') i=$((i + 1)); skip_group '(' ')' ;; esac
  while ((i < n)); do
    c="${src:i:1}"
    case "$c" in
      ' '|$'\t'|"$nl"|';'|'&'|'|'|'<'|'>'|')') break ;;
      '(')
        case "${src:s:i-s}" in *=) skip_group '(' ')' ;; *) break ;; esac ;;
      \\) i=$((i + 2)) ;;
      \') skip_squote ;;
      \") skip_dquote ;;
      \`) skip_bq ;;
      \$)
        case "${src:i+1:1}" in
          \() i=$((i + 1)); skip_group '(' ')' ;;
          \{) i=$((i + 1)); skip_group '{' '}' ;;
          *) i=$((i + 1)) ;;
        esac ;;
      *) i=$((i + 1)) ;;
    esac
  done
  ((i <= n)) || i=$n
  w="${src:s:i-s}"
  if [[ "$w" =~ ^[0-9]+$ ]]; then
    case "${src:i:1}" in '<'|'>') return ;; esac
  fi
  if [ -n "$want_delim" ]; then
    heredocs+=("$want_delim:${w//[\'\"\\]/}"); want_delim=""
  fi
  emit W "$w" "$s"
}

while ((i < n)); do
  c="${src:i:1}" two="${src:i:2}" three="${src:i:3}"
  case "$c" in
    ' '|$'\t') i=$((i + 1)) ;;
    "$nl")
      emit N "" "$i"; i=$((i + 1))
      ((${#heredocs[@]} == 0)) || skip_heredocs ;;
    \\)
      if [ "$two" = "\\$nl" ]; then i=$((i + 2)); else word; fi ;;
    '#')
      rest="${src:i}"; cm="${rest%%"$nl"*}"; i=$((i + ${#cm})) ;;
    ';')
      if [ "$three" = ';;&' ]; then emit O ';;&' "$i"; i=$((i + 3))
      elif [ "$two" = ';;' ] || [ "$two" = ';&' ]; then emit O "$two" "$i"; i=$((i + 2))
      else emit O ';' "$i"; i=$((i + 1)); fi ;;
    '&')
      if [ "$two" = '&&' ]; then emit O '&&' "$i"; i=$((i + 2))
      elif [ "$three" = '&>>' ]; then emit R '&>>' "$i"; i=$((i + 3))
      elif [ "$two" = '&>' ]; then emit R '&>' "$i"; i=$((i + 2))
      else emit O '&' "$i"; i=$((i + 1)); fi ;;
    '|')
      if [ "$two" = '||' ] || [ "$two" = '|&' ]; then emit O "$two" "$i"; i=$((i + 2))
      else emit O '|' "$i"; i=$((i + 1)); fi ;;
    '<'|'>')
      if [ "${src:i+1:1}" = '(' ]; then word
      elif [ "$three" = '<<<' ]; then emit R '<<<' "$i"; i=$((i + 3))
      elif [ "$three" = '<<-' ]; then emit R '<<-' "$i"; i=$((i + 3)); want_delim=-
      elif [ "$two" = '<<' ]; then emit R '<<' "$i"; i=$((i + 2)); want_delim=+
      else
        case "$two" in
          '>>'|'>|'|'<>'|'<&'|'>&') emit R "$two" "$i"; i=$((i + 2)) ;;
          *) emit R "$c" "$i"; i=$((i + 1)) ;;
        esac
      fi ;;
    '(')
      if [ "$two" = '((' ]; then s=$i; skip_group '(' ')'; emit A "" "$s"
      else emit O '(' "$i"; i=$((i + 1)); fi ;;
    ')') emit O ')' "$i"; i=$((i + 1)) ;;
    *) word ;;
  esac
done
emit E "" "$n"

fty=(ROOT) fst=(body) ffind=("") fneg=(0) ffn=(0) fln=(1)
k=0 cmdpos=1 negate=0 pendfunc=0

top() { echo $((${#fty[@]} - 1)); }
push() {
  fty+=("$1"); fst+=("$2"); ffind+=(""); fneg+=("$negate"); ffn+=("$pendfunc"); fln+=("${tl[k]}")
  negate=0 pendfunc=0
}
popped_ty="" popped_find="" popped_neg=0 popped_fn=0 popped_ln=0
pop() {
  local t; t=$(top)
  ((t > 0)) || return 1
  popped_ty="${fty[t]}" popped_find="${ffind[t]}" popped_neg="${fneg[t]}" popped_fn="${ffn[t]}" popped_ln="${fln[t]}"
  unset 'fty[t]' 'fst[t]' 'ffind[t]' 'fneg[t]' 'ffn[t]' 'fln[t]'
}
pop_to() {
  local t want
  t=$(top)
  while ((t > 0)); do
    for want in "$@"; do [ "${fty[t]}" != "$want" ] || { pop; return 0; }; done
    t=$((t - 1))
  done
  return 1
}
exempt() {
  local t
  for ((t = $(top); t > 0; t--)); do
    case "${fty[t]}" in SUB|OTHER) return 0 ;; esac
    [ "${fst[t]}" != cond ] || return 0
  done
  return 1
}
skip_redirs() {
  while [ "${tk[k]}" = R ]; do
    k=$((k + 1)); [ "${tk[k]}" != W ] || k=$((k + 1))
  done
}
handled_next() {
  [ "${tk[k]}" = O ] || return 1
  case "${tt[k]}" in '||'|'&&'|'|'|'|&'|'&') return 0 ;; esac
  return 1
}
last_command() {
  local j=$k t
  while [ "${tk[j]}" = N ] || { [ "${tk[j]}" = O ] && [ "${tt[j]}" = ';' ]; }; do j=$((j + 1)); done
  t=$(top)
  if [ "${tk[j]}" = E ] && ((t == 0)); then return 0; fi
  [ "${tk[j]}" = W ] && [ "${tt[j]}" = '}' ] && [ "${fty[t]}" = FUNC ]
}
report() {
  local t; t=$(top)
  ffind[t]+="$1|$2|$3$nl"
}
check() {
  local kind="$1" from="$2" to="$3" neg="$4" fn="$5"
  skip_redirs
  cmdpos=0
  handled_next && return
  [ "$neg" = 0 ] && [ "$fn" = 0 ] || return
  exempt && return
  last_command && return
  report "$kind" "$from" "$to"
}
closed_compound() {
  local find="$popped_find" t
  skip_redirs
  cmdpos=0
  if [ "$popped_ty" != FUNC ]; then
    handled_next && return
    [ "$popped_neg" = 0 ] || return
  fi
  t=$(top)
  ffind[t]+="$find"
}

while :; do
  kind="${tk[k]}" text="${tt[k]}"
  t=$(top)
  case "$kind" in
    E) break ;;
    N)
      k=$((k + 1))
      [ "${fst[t]}" = words ] || { cmdpos=1; negate=0; } ;;
    R)
      k=$((k + 1)); [ "${tk[k]}" != W ] || k=$((k + 1)) ;;
    A)
      k=$((k + 1))
      if ((cmdpos)) && [ "${fst[t]}" != words ]; then
        check arith "${tl[k-1]}" "${tl[k-1]}" "$negate" 0
      fi
      cmdpos=0 ;;
    O)
      case "$text" in
        ';'|'&'|'&&'|'||'|'|'|'|&')
          k=$((k + 1)); cmdpos=1
          case "$text" in '|'|'|&') ;; *) negate=0 ;; esac ;;
        ';;'|';&'|';;&')
          k=$((k + 1)); cmdpos=1; negate=0
          if [ "${fty[t]}" = CASE ]; then fst[t]=pattern; fi ;;
        '(')
          k=$((k + 1))
          if [ "${fty[t]}" = CASE ] && [ "${fst[t]}" = pattern ]; then continue; fi
          if ((cmdpos)); then k=$((k - 1)); push SUB body; k=$((k + 1)); else push OTHER body; fi
          cmdpos=1 ;;
        ')')
          k=$((k + 1))
          if [ "${fty[t]}" = SUB ]; then
            pop
            check subshell "$popped_ln" "${tl[k-1]}" "$popped_neg" "$popped_fn"
          else
            [ "${fty[t]}" != OTHER ] || pop
            cmdpos=0
          fi ;;
        *) k=$((k + 1)) ;;
      esac ;;
    W)
      if [ "${fty[t]}" = CASE ] && [ "${fst[t]}" = word ]; then
        [ "$text" != in ] || fst[t]=pattern
        k=$((k + 1)); continue
      fi
      if [ "${fty[t]}" = CASE ] && [ "${fst[t]}" = pattern ]; then
        if [ "$text" = 'esac' ]; then k=$((k + 1)); pop; closed_compound; continue; fi
        while [ "${tk[k]}" != E ] && ! { [ "${tk[k]}" = O ] && [ "${tt[k]}" = ')' ]; }; do k=$((k + 1)); done
        [ "${tk[k]}" = E ] || k=$((k + 1))
        fst[t]=body; cmdpos=1; continue
      fi
      if [ "${fst[t]}" = words ]; then
        k=$((k + 1))
        if [ "$text" = 'do' ]; then fst[t]=body; cmdpos=1; fi
        continue
      fi
      if ((!cmdpos)); then k=$((k + 1)); continue; fi
      case "$text" in
        'if') push IF cond; k=$((k + 1)) ;;
        'while'|'until') push LOOP cond; k=$((k + 1)) ;;
        'for'|'select') push LOOP words; k=$((k + 1)); cmdpos=0 ;;
        'case') push CASE word; k=$((k + 1)); cmdpos=0 ;;
        'then'|'else') [ "${fty[t]}" != IF ] || fst[t]=body; k=$((k + 1)) ;;
        'elif') [ "${fty[t]}" != IF ] || fst[t]=cond; k=$((k + 1)) ;;
        'do') [ "${fty[t]}" != LOOP ] || fst[t]=body; k=$((k + 1)) ;;
        'fi') k=$((k + 1)); if pop_to IF; then closed_compound; else cmdpos=0; fi ;;
        'done') k=$((k + 1)); if pop_to LOOP; then closed_compound; else cmdpos=0; fi ;;
        'esac') k=$((k + 1)); if pop_to CASE; then closed_compound; else cmdpos=0; fi ;;
        '{') if ((pendfunc)); then push FUNC body; else push BRACE body; fi; k=$((k + 1)) ;;
        '}') k=$((k + 1)); if pop_to BRACE FUNC; then closed_compound; else cmdpos=0; fi ;;
        '!') negate=1; k=$((k + 1)) ;;
        '[[')
          from="${tl[k]}"
          while [ "${tk[k]}" != E ] && ! { [ "${tk[k]}" = W ] && [ "${tt[k]}" = ']]' ]; }; do k=$((k + 1)); done
          to="${tl[k]}"
          [ "${tk[k]}" = E ] || k=$((k + 1))
          check test "$from" "$to" "$negate" 0 ;;
        function)
          k=$((k + 2))
          if [ "${tk[k]}" = O ] && [ "${tt[k]}" = '(' ] && [ "${tk[k+1]}" = O ] && [ "${tt[k+1]}" = ')' ]; then k=$((k + 2)); fi
          pendfunc=1 ;;
        *)
          if [ "${tk[k+1]}" = O ] && [ "${tt[k+1]}" = '(' ] && [ "${tk[k+2]}" = O ] && [ "${tt[k+2]}" = ')' ]; then
            k=$((k + 3)); pendfunc=1
          else
            k=$((k + 1)); cmdpos=0; pendfunc=0
          fi ;;
      esac ;;
  esac
done

while pop; do ffind[0]+="$popped_find"; done
mapfile -t lines <<< "$src"
found=0
while IFS='|' read -r what from to; do
  [ -n "$what" ] || continue
  found=1
  case "$what" in
    subshell) thing='a ( … ) subshell' fix='( cd dir && make ) || exit 1' ;;
    test) thing='a [[ … ]] test' fix="[[ \$x = y ]] || exit 1" ;;
    arith) thing='a (( … )) command' fix='(( n > 0 )) || exit 1' ;;
  esac
  where="line $from"; [ "$to" = "$from" ] || where="lines $from-$to"
  echo "::error title=mavericks-vm::$name, $where: $thing whose status nothing checks. The guest's sh is bash 3.2.53, which does not stop under sh -e when it fails, so the step would pass. End it with || exit 1, as in $fix (or make it an if condition)."
  for ((l = from; l <= to; l++)); do printf '%6d | %s\n' "$l" "${lines[l-1]-}"; done
done <<< "${ffind[0]}"
exit "$found"
