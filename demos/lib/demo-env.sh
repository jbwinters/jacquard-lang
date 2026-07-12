#!/usr/bin/env sh

# Shared launcher support for demos distributed in both source checkouts and
# binary release archives. The caller must set JACQUARD_DEMO_ROOT to demos/.

if [ -z "${JACQUARD_DEMO_ROOT:-}" ]; then
  echo "demo launcher bug: JACQUARD_DEMO_ROOT is not set" >&2
  exit 1
fi

jacquard_demo_checkout=$(CDPATH= cd -- "$JACQUARD_DEMO_ROOT/.." && pwd)

if [ -n "${JACQUARD:-}" ]; then
  jacquard_demo_mode=explicit
elif [ -f "$jacquard_demo_checkout/dune-project" ]; then
  jacquard_demo_binary="$jacquard_demo_checkout/_build/default/bin/main.exe"
  if [ ! -x "$jacquard_demo_binary" ]; then
    echo "this source-checkout demo requires a built CLI" >&2
    echo "run eval \"\$(opam env)\" && opam exec -- dune build @all" >&2
    exit 1
  fi
  : "${JACQUARD_PRELUDE:=$jacquard_demo_checkout/prelude}"
  export JACQUARD_PRELUDE
  jacquard_demo_mode=checkout
elif command -v jac >/dev/null 2>&1; then
  JACQUARD=$(command -v jac)
  jacquard_demo_mode=installed
elif command -v jacquard >/dev/null 2>&1; then
  JACQUARD=$(command -v jacquard)
  jacquard_demo_mode=installed
else
  echo "cannot find jac or jacquard on PATH" >&2
  echo "install Jacquard or set JACQUARD=/path/to/jac" >&2
  exit 127
fi

if [ -z "${TMPDIR:-}" ]; then
  if [ "$jacquard_demo_mode" = checkout ]; then
    TMPDIR="$jacquard_demo_checkout/.scratch/tmp"
  else
    TMPDIR="${XDG_CACHE_HOME:-$HOME/.cache}/jacquard/tmp"
  fi
  export TMPDIR
fi
mkdir -p "$TMPDIR"

jacquard_demo() {
  if [ "$jacquard_demo_mode" = checkout ]; then
    "$jacquard_demo_binary" "$@"
  else
    "$JACQUARD" "$@"
  fi
}
