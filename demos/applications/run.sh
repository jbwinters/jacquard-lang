#!/usr/bin/env sh
# Launcher for the four everyday applications kept as acceptance fixtures.
#
#   demos/applications/run.sh APP demo            # the recorded demo transcript
#   demos/applications/run.sh APP interactive     # reads the application's input from stdin
#   demos/applications/run.sh APP check           # project check: grants must match authority
#   demos/applications/run.sh APP test            # the application's Warp suite (routine lane)
#   demos/applications/run.sh APP build OUT       # native binary for the demo entry point
#   demos/applications/run.sh APP build-interactive OUT
#
# APP is dice-coach, picnic-planner, rota-optimizer, or formula-notebook. Each
# application is a local project (project.jqd); this script is a thin wrapper
# over `jacquard project`. JACQUARD_APPLICATIONS_EXHAUSTIVE=1 makes `test` run
# the full exhaustive property lane instead of the routine one.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
JACQUARD_DEMO_ROOT=$(CDPATH= cd -- "$here/.." && pwd)
. "$JACQUARD_DEMO_ROOT/lib/demo-env.sh"

app=${1:?usage: run.sh APP demo|interactive|check|test|build OUT|build-interactive OUT}
action=${2:?usage: run.sh APP demo|interactive|check|test|build OUT|build-interactive OUT}
dir=$here/$app
[ -f "$dir/project.jqd" ] || { echo "run.sh: unknown application $app" >&2; exit 2; }

if [ "${JACQUARD_APPLICATIONS_EXHAUSTIVE:-0}" = 1 ]; then
  lane="--exhaustive"
else
  lane=""
fi

case $action in
  demo | interactive)
    jacquard_demo project run --project "$dir" "$action" --allow console
    ;;
  check)
    jacquard_demo project check --project "$dir" --strict-grants
    ;;
  test)
    case $app in
      dice-coach | picnic-planner)
        # one combined suite, as before: the display tests, both models'
        # suites, and the shared interaction tests, each run in the project
        # that owns it; the last line sums the four summaries
        summaries=$(mktemp "$TMPDIR/jacquard-$app.XXXXXX")
        trap 'rm -f "$summaries"' EXIT
        status=0
        for project in shared dice-coach picnic-planner suite; do
          jacquard_demo project test --project "$here/$project" --seed 42 $lane --no-cache \
            > "$summaries.one" || status=1
          grep -v ' passed, .* refused$' "$summaries.one" || true
          grep ' passed, .* refused$' "$summaries.one" >> "$summaries" || true
        done
        rm -f "$summaries.one"
        awk '/ passed, .* refused$/ { p += $1; f += $3; s += $5; r += $7 }
             END { printf "%d passed, %d failed, %d skipped, %d refused\n", p, f, s, r }' "$summaries"
        exit $status
        ;;
      *)
        jacquard_demo project test --project "$dir" --seed 42 $lane --no-cache
        ;;
    esac
    ;;
  build | build-interactive)
    out=${3:?usage: run.sh APP build OUT}
    case $action in build) entry=demo ;; *) entry=interactive ;; esac
    jacquard_demo project build --project "$dir" "$entry" -o "$out"
    ;;
  *)
    echo "run.sh: unknown action $action" >&2
    exit 2
    ;;
esac
