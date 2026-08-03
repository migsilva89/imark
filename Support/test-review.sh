#!/bin/bash
#
# The round trip: the plugin opens a review and waits, the app writes a decision,
# the plugin wakes up and produces what the agent will read.
#
#   Support/test-review.sh
#
# Everything here is the real code on both sides. The decision is written by
# Review.decide — the function the toolbar buttons call — rather than by a
# click, because posting a synthetic click needs accessibility permission that a
# terminal does not have. That one hop, button to selector, is the only part of
# this feature no test covers.

set -uo pipefail
cd "$(dirname "$0")/.."

pass=0
fail=0
check() {
  if [[ "$2" == *"$3"* ]]; then
    echo "OK   $1"
    pass=$((pass + 1))
  else
    echo "FALHA $1"
    fail=$((fail + 1))
  fi
}
refute() {
  if [[ "$2" == *"$3"* ]]; then
    echo "FALHA $1"
    fail=$((fail + 1))
  else
    echo "OK   $1"
    pass=$((pass + 1))
  fi
}

echo "▸ a compilar o decisor"
swiftc -parse-as-library \
  Sources/Imark/Review.swift Support/decide.swift \
  -o /tmp/imark-decide 2>/dev/null || {
    echo "FALHA não compilou"; exit 1;
  }

run() {   # run <decisão> <notas-no-documento>  → imprime o que o agente lê
  local decision="$1" note="$2"
  local dir; dir="$(mktemp -d)"
  cd "$dir"
  {
    echo "# Plano"
    echo
    echo "Um parágrafo que vai ser revisto."
    echo
    if [[ -n "$note" ]]; then
      echo '<!-- imark quote="vai ser revisto" by="miguel" at="2026-08-03T15:00Z"'
      echo "$note"
      echo '-->'
    fi
  } > SPEC.md

  IMARK_TEST_NO_OPEN=1 node "$OLDPWD/plugin/scripts/imark.mjs" review SPEC.md > out.txt 2>&1 &
  local pid=$!

  local review=""
  for _ in $(seq 1 40); do
    review="$(ls .imark/reviews/*.md 2>/dev/null | head -1)"
    [[ -n "$review" ]] && break
    sleep 0.25
  done
  if [[ -z "$review" ]]; then
    kill "$pid" 2>/dev/null
    echo "FALHA a revisão nunca foi escrita"
    cd "$OLDPWD"; return 1
  fi

  /tmp/imark-decide "$review" "$decision" 1 > /dev/null
  wait "$pid"
  cat out.txt
  cd "$OLDPWD"
  rm -rf "$dir"
}

echo "▸ pedir alterações"
out="$(run request-changes 'Isto está ambíguo e precisa de um número.')"
check "diz ao agente que não foi aprovado"    "$out" "THE REVIEWER DID NOT APPROVE THIS"
check "manda-o não reescrever já"             "$out" "Do not rewrite anything yet"
check "manda-o perguntar quando há dúvida"    "$out" "Do not guess"
check "leva a nota que escrevi"               "$out" "Isto está ambíguo"
check "e a frase a que ela se refere"         "$out" "vai ser revisto"
refute "não a dá como órfã"                   "$out" "Órfã"

echo "▸ aprovar"
out="$(run approve 'Uma nota a ter em conta.')"
check "diz ao agente que foi aprovado"        "$out" "APPROVED"
check "e passa-lhe as notas na mesma"         "$out" "Uma nota a ter em conta"
refute "sem a ordem de reescrever"            "$out" "DID NOT APPROVE"

echo "▸ o gancho do modo de planear"

hook() {   # hook <ligado|desligado> <decisão> → imprime o JSON que o Claude Code lê
  local gate="$1" decision="$2"
  local dir; dir="$(mktemp -d)"
  cd "$dir"
  # The shape Claude Code puts on stdin when ExitPlanMode asks for permission.
  node -e 'require("fs").writeFileSync("ev.json", JSON.stringify({
    tool_input: { plan: "# Plano\n\nUm passo que vai ser revisto.\n" },
    cwd: process.cwd(),
  }))'

  if [[ "$gate" == desligado ]]; then
    node "$OLDPWD/plugin/scripts/imark.mjs" plan-hook < ev.json
    cd "$OLDPWD"; rm -rf "$dir"; return
  fi

  IMARK_TEST_NO_OPEN=1 IMARK_PLAN_REVIEW=1 \
    node "$OLDPWD/plugin/scripts/imark.mjs" plan-hook < ev.json > out.json 2>/dev/null &
  local pid=$!
  local review=""
  for _ in $(seq 1 40); do
    review="$(ls .imark/reviews/*.md 2>/dev/null | head -1)"
    [[ -n "$review" ]] && break
    sleep 0.25
  done
  [[ -n "$review" ]] && /tmp/imark-decide "$review" "$decision" 0 > /dev/null
  wait "$pid"
  cat out.json
  cd "$OLDPWD"; rm -rf "$dir"
}

out="$(hook desligado approve)"
check "sem IMARK_PLAN_REVIEW não faz nada"    "$out" "{}"
refute "e não decide o pedido"                "$out" "behavior"

out="$(hook ligado request-changes)"
check "pedir alterações recusa a permissão"   "$out" '"behavior":"deny"'
check "com a ordem de rever no motivo"        "$out" "DID NOT APPROVE"

out="$(hook ligado approve)"
check "aprovar deixa o agente seguir"         "$out" '"behavior":"allow"'
refute "sem voltar a perguntar no terminal"   "$out" "deny"

echo
if [[ $fail -eq 0 ]]; then
  echo "all good ($pass)"
else
  echo "$fail a falhar de $((pass + fail))"
  exit 1
fi
