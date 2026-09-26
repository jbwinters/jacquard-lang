#!/usr/bin/env sh
# Import the four everyday applications from their development checkout into
# demos/applications as maintained acceptance fixtures (APP.11).
#
#   scripts/applications/import.sh /path/to/projects
#
# Only the authored Jacquard sources and the recorded example transcripts are
# copied; journals, timing files, and scratch directories stay where they are.
# demos/applications/MANIFEST.sha256 records the SHA-256 of every imported file
# so `sha256sum -c` proves which snapshot a fixture set came from. The originals
# are never modified.
set -eu

source_root=${1:?usage: import.sh SOURCE_DIR}
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
target=$(CDPATH= cd -- "$here/../.." && pwd)/demos/applications

copy() {
  from=$source_root/$1
  to=$target/$2
  [ -f "$from" ] || { echo "import: missing $from" >&2; exit 1; }
  mkdir -p "$(dirname -- "$to")"
  cp -- "$from" "$to"
}

# shared display helpers used by dice-coach and picnic-planner
copy display.jac shared/display.jac
copy display-tests.jac shared/display-tests.jac
copy interaction-tests.jac suite/interaction-tests.jac

for file in model.jac tests.jac demo.jac interactive.jac EXAMPLE.txt; do
  copy dice-coach/$file dice-coach/$file
  copy picnic-planner/$file picnic-planner/$file
done

for file in model.jac fixtures.jac report.jac tests.jac interaction-tests.jac \
  custom-example.jac demo.jac interactive.jac EXAMPLE.txt CUSTOM-EXAMPLE.txt; do
  copy rota-optimizer/$file rota-optimizer/$file
done

for file in syntax.jac model.jac commands.jac application.jac workbook.jac \
  smoke.jac parser-tests.jac model-tests.jac interaction-tests.jac demo.jac \
  interactive.jac EXAMPLE.txt; do
  copy formula-notebook/$file formula-notebook/$file
done

(cd "$target" && find . -type f \( -name '*.jac' -o -name '*.txt' \) | sort \
  | sed 's|^\./||' | xargs sha256sum) > "$target/MANIFEST.sha256"
echo "imported $(wc -l < "$target/MANIFEST.sha256") files into $target"
