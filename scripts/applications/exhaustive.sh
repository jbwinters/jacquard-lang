#!/usr/bin/env sh
# The exhaustive application lane (APP.11): every Warp suite with --exhaustive,
# then interpreter/native parity of each demo transcript. Run from anywhere:
#
#   JACQUARD=/path/to/jac scripts/applications/exhaustive.sh demos/applications prelude
#
# or through dune: `dune build @applications-exhaustive`.
set -eu

apps=${1:?usage: exhaustive.sh demos/applications prelude}
prelude=${2:?usage: exhaustive.sh demos/applications prelude}
apps=$(CDPATH= cd -- "$apps" && pwd)
JACQUARD_PRELUDE=$(CDPATH= cd -- "$prelude" && pwd)
export JACQUARD_PRELUDE
case ${JACQUARD:-} in
  "") ;;
  /*) ;;
  *) JACQUARD=$(pwd)/$JACQUARD; export JACQUARD ;;
esac
: "${TMPDIR:=$apps/../../.scratch/tmp}"
export TMPDIR
mkdir -p "$TMPDIR"
work=$(mktemp -d "$TMPDIR/jacquard-applications.XXXXXX")
trap 'rm -rf "$work"' EXIT

status=0
for app in dice-coach rota-optimizer formula-notebook; do
  echo "== exhaustive suite: $app =="
  if JACQUARD_APPLICATIONS_EXHAUSTIVE=1 sh "$apps/run.sh" "$app" test > "$work/$app.test" 2>&1; then
    tail -1 "$work/$app.test"
  else
    echo "FAILED: $app"; tail -20 "$work/$app.test"; status=1
  fi
done

for app in dice-coach picnic-planner rota-optimizer formula-notebook; do
  echo "== native parity: $app =="
  sh "$apps/run.sh" "$app" build "$work/$app" > /dev/null
  "$work/$app" --allow console > "$work/$app.native" 2>&1 || true
  if cmp -s "$work/$app.native" "$apps/$app/EXAMPLE.txt"; then
    echo "identical: $app"
  else
    echo "DIFFERS: $app"; diff "$work/$app.native" "$apps/$app/EXAMPLE.txt" | head -10; status=1
  fi
done
exit $status
