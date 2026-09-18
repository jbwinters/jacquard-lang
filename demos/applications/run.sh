#!/usr/bin/env sh
# Launcher for the four everyday applications kept as acceptance fixtures.
#
#   demos/applications/run.sh APP demo            # the recorded demo transcript
#   demos/applications/run.sh APP interactive     # reads the application's input from stdin
#   demos/applications/run.sh APP check           # manifest check: the demo needs only Console
#   demos/applications/run.sh APP test            # the application's Warp suite (routine lane)
#   demos/applications/run.sh APP build OUT       # native binary for the demo entry point
#   demos/applications/run.sh APP build-interactive OUT
#
# APP is dice-coach, picnic-planner, rota-optimizer, or formula-notebook.
# Each entry point is assembled by concatenating the authored files exactly as
# the applications' own instructions do; the assembled file lives under
# $TMPDIR and is removed on exit. JACQUARD_APPLICATIONS_EXHAUSTIVE=1 makes
# `test` run the full exhaustive property lane instead of the routine one.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
JACQUARD_DEMO_ROOT=$(CDPATH= cd -- "$here/.." && pwd)
. "$JACQUARD_DEMO_ROOT/lib/demo-env.sh"

app=${1:?usage: run.sh APP demo|interactive|check|test|build OUT|build-interactive OUT}
action=${2:?usage: run.sh APP demo|interactive|check|test|build OUT|build-interactive OUT}
dir=$here/$app
[ -d "$dir" ] || { echo "run.sh: unknown application $app" >&2; exit 2; }

case $app in
  dice-coach | picnic-planner)
    core="$here/shared/display.jac $dir/model.jac"
    # the two applications share one suite: the display helpers and the
    # interaction tests exercise both models together
    suite="$here/shared/display.jac $here/shared/display-tests.jac $here/dice-coach/model.jac $here/dice-coach/tests.jac $here/picnic-planner/model.jac $here/picnic-planner/tests.jac $here/shared/interaction-tests.jac"
    ;;
  rota-optimizer)
    core="$dir/model.jac $dir/fixtures.jac $dir/report.jac"
    suite="$dir/model.jac $dir/fixtures.jac $dir/report.jac $dir/tests.jac $dir/interaction-tests.jac"
    ;;
  formula-notebook)
    core="$dir/syntax.jac $dir/model.jac $dir/commands.jac $dir/application.jac"
    suite="$dir/syntax.jac $dir/model.jac $dir/commands.jac $dir/application.jac $dir/workbook.jac $dir/parser-tests.jac $dir/model-tests.jac $dir/interaction-tests.jac"
    ;;
esac

assembled=$(mktemp "$TMPDIR/jacquard-$app.XXXXXX.jac")
trap 'rm -f "$assembled"' EXIT

assemble() {
  # $1 = entry: demo or interactive
  if [ "$app" = formula-notebook ] && [ "$1" = demo ]; then
    cat $core "$dir/workbook.jac" "$dir/demo.jac" > "$assembled"
  else
    cat $core "$dir/$1.jac" > "$assembled"
  fi
}

case $action in
  demo)
    assemble demo
    jacquard_demo run "$assembled" --allow console
    ;;
  interactive)
    assemble interactive
    jacquard_demo run "$assembled" --allow console
    ;;
  check)
    assemble demo
    jacquard_demo check "$assembled" --manifest console
    ;;
  test)
    if [ "${JACQUARD_APPLICATIONS_EXHAUSTIVE:-0}" = 1 ]; then
      jacquard_demo test $suite --seed 42 --exhaustive --no-cache
    else
      jacquard_demo test $suite --seed 42 --no-cache
    fi
    ;;
  build | build-interactive)
    out=${3:?usage: run.sh APP build OUT}
    case $action in build) assemble demo ;; *) assemble interactive ;; esac
    # the native compiler writes its object cache relative to the working
    # directory; build from the assembled file's directory so nothing lands in
    # the caller's tree
    ( cd "$(dirname -- "$assembled")" && jacquard_demo build "$assembled" -o "$out" )
    ;;
  *)
    echo "run.sh: unknown action $action" >&2
    exit 2
    ;;
esac
