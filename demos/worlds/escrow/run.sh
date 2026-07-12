#!/usr/bin/env sh
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
JACQUARD_DEMO_ROOT=$(CDPATH= cd -- "$here/../.." && pwd)
. "$JACQUARD_DEMO_ROOT/lib/demo-env.sh"

work=$(mktemp -d "$TMPDIR/jacquard-escrow.XXXXXX")
trap 'rm -rf "$work"' EXIT
cp "$here"/*.jqd "$here/APPROVAL" "$work/"
cd "$work"

cat workflow.jqd main.jqd > approved-run.jqd
cat workflow-escalated.jqd main.jqd > escalated-run.jqd
printf 'cfg' > release-config.txt

expect_exit() {
  expected=$1
  shift
  set +e
  "$@"
  actual=$?
  set -e
  if [ "$actual" -ne "$expected" ]; then
    echo "expected exit $expected, got $actual: $*" >&2
    exit 1
  fi
  echo "exit code: $actual (expected)"
}

echo "== authority is inferred from the workflow =="
jacquard_demo check workflow.jqd --print-sigs

echo "== no grants: capability refusal before execution =="
expect_exit 3 jacquard_demo run approved-run.jqd

echo "== dry-run: intended actions, no receipt mutation =="
jacquard_demo run approved-run.jqd --dry-run
test ! -e receipt.txt

echo "== granted run in the isolated demo workspace =="
jacquard_demo run approved-run.jqd --allow fs --allow net --allow console
printf 'receipt: '
cat receipt.txt
printf '\n'

echo "== Warp: hermetic and exhaustive lanes =="
jacquard_demo test tests.jqd --seed 7 --cache-dir escrow-cache
jacquard_demo test tests.jqd --seed 7 --cache-dir escrow-cache --exhaustive

echo "== record and strict replay =="
cat > mklog.jqd <<'JACQUARD'
(app (var throw.catch)
  (lam ()
    (match
      (app (var net.scripted)
        (lam () (app (var net.record)
          (lam ()
            (match (app (var fetch) (app (var mk-request) (lit "http://registry/publish") (lit "cfg")))
              (clause (pcon mk-response (pwild) (pvar receipt)) (var receipt))))))
        (app (var cons) (app (var mk-response) (lit 200) (lit "R-77")) (var nil)))
      (clause (ptuple (pvar result) (pvar log)) (var log))))
  (lam ((pwild)) (quote (log))))
JACQUARD
jacquard_demo run mklog.jqd | sed -e 's/^(quote //' -e 's/)$//' > trace.jqd
cat > replay-prog.jqd <<'JACQUARD'
(match (app (var fetch) (app (var mk-request) (lit "http://registry/publish") (lit "cfg")))
  (clause (pcon mk-response (pwild) (pvar receipt)) (var receipt)))
JACQUARD
jacquard_demo replay trace.jqd replay-prog.jqd

echo "== metadata does not alter identity =="
cp workflow.jqd workflow-comment.jqd
printf '\n; provenance note: reviewer saw this exact workflow\n' >> workflow-comment.jqd
jacquard_demo diff workflow.jqd workflow-comment.jqd

echo "== broader authority is exposed and refused =="
jacquard_demo check workflow-escalated.jqd --print-sigs
expect_exit 1 jacquard_demo check escalated-run.jqd --manifest fs,net,console
jacquard_demo diff workflow.jqd workflow-escalated.jqd | grep -E '^(changed|    [+-])' | head -n 3

echo "== approval is bound to the exact semantic hash =="
approved=$(awk '/^member-hash:/ { print $2 }' APPROVAL)
actual=$(jacquard_demo hash workflow.jqd | awk '/0:escrow.workflow/ { print $2 }')
test "$approved" = "$actual"
echo "approved hash: $actual"
sed 's/(lit "receipt.txt")/(lit "receipt-v2.txt")/' workflow.jqd > workflow-changed.jqd
changed=$(jacquard_demo hash workflow-changed.jqd | awk '/0:escrow.workflow/ { print $2 }')
test "$approved" != "$changed"
echo "changed hash:  $changed (approval invalidated)"
