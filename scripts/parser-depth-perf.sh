#!/bin/sh
set -eu

# DX.6 opt-in performance guard. This is deliberately outside Dune's default
# test aliases because wall-clock assertions are unsuitable for shared CI hosts.

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
depth=${JACQUARD_PARSER_DEPTH:-100000}
deadline=${JACQUARD_PARSER_DEADLINE:-10}
bin=${JACQUARD_BIN:-$repo_root/_build/default/bin/main.exe}
work=$repo_root/.scratch/parser-depth-perf

if command -v timeout >/dev/null 2>&1; then
  timeout_bin=timeout
elif command -v gtimeout >/dev/null 2>&1; then
  timeout_bin=gtimeout
else
  echo "parser-depth-perf: install GNU timeout (coreutils)" >&2
  exit 2
fi

if [ ! -x "$bin" ]; then
  echo "parser-depth-perf: build the Jacquard binary first: dune build @all" >&2
  exit 2
fi

mkdir -p "$work"

awk -v depth="$depth" 'BEGIN {
  for (i = 0; i < depth; i++) printf "(";
  printf "0";
  for (i = 0; i < depth; i++) printf ")";
  printf "\n";
}' > "$work/deep.jac"

awk -v depth="$depth" 'BEGIN {
  for (i = 0; i < depth; i++) printf "(quote ";
  printf "(lit 0)";
  for (i = 0; i < depth; i++) printf ")";
  printf "\n";
}' > "$work/deep.jqd"

if [ "${JACQUARD_PARSER_GENERATE_ONLY:-0}" = 1 ]; then
  echo "$work/deep.jac"
  echo "$work/deep.jqd"
  exit 0
fi

export JACQUARD_PRELUDE=${JACQUARD_PRELUDE:-$repo_root/prelude}

run_case() {
  label=$1
  expected=$2
  source=$3
  stdout=$work/$label.stdout
  stderr=$work/$label.stderr

  set +e
  "$timeout_bin" "$deadline" "$bin" check "$source" >"$stdout" 2>"$stderr"
  code=$?
  set -e

  if [ "$code" -eq 124 ]; then
    echo "$label: exceeded ${deadline}s deadline" >&2
    exit 1
  fi
  if [ "$code" -ne 1 ]; then
    echo "$label: expected diagnostic exit 1, got $code" >&2
    cat "$stderr" >&2
    exit 1
  fi
  expected_count=$(grep -c "error\[$expected\]" "$stderr" || true)
  error_count=$(grep -c 'error\[' "$stderr" || true)
  if [ "$expected_count" -ne 1 ] || [ "$error_count" -ne 1 ]; then
    echo "$label: expected exactly one $expected diagnostic" >&2
    cat "$stderr" >&2
    exit 1
  fi
  if grep -Eq 'E0003|Stack_overflow|internal error' "$stderr"; then
    echo "$label: escaped the structural guard" >&2
    cat "$stderr" >&2
    exit 1
  fi
  echo "$label: $expected within ${deadline}s at depth $depth"
}

run_case surface E1227 "$work/deep.jac"
run_case bootstrap E0115 "$work/deep.jqd"
