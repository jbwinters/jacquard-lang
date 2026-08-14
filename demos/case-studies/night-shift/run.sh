#!/usr/bin/env sh
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
JACQUARD_DEMO_ROOT=$(CDPATH= cd -- "$here/../.." && pwd)
. "$JACQUARD_DEMO_ROOT/lib/demo-env.sh"
suite=$(mktemp "$TMPDIR/jacquard-night-shift-tests.XXXXXX.jac")
shift_out=$(mktemp "$TMPDIR/jacquard-night-shift-run.XXXXXX.out")
relate_out=$(mktemp "$TMPDIR/jacquard-night-shift-relate.XXXXXX.out")
trap 'rm -f "$suite" "$shift_out" "$relate_out"' EXIT

echo "== the shift's authority, inferred from the source =="
jacquard_demo check "$here/model.jac" --print-sigs

echo "== ungranted: the forecast still runs, the lever refuses (expect E0814) =="
if jacquard_demo run "$here/model.jac"; then
  echo "night-shift demo bug: ungranted run must refuse" >&2
  exit 1
else
  echo "refused with exit $?"
fi

echo "== granted: the whole shift, token redacted end to end =="
# The exact latest-version key for the SecretRef name `night-shift-token`
# (JACQUARD_SECRET_V0_ + lowercase hex of the name). The payload is assembled
# so its literal spelling appears nowhere in this script or the transcript.
token_key=JACQUARD_SECRET_V0_6e696768742d73686966742d746f6b656e_LATEST
token_payload="nsk-$(printf live)-7788"
export "$token_key=$token_payload"
jacquard_demo run "$here/model.jac" --allow eval --allow secret > "$shift_out"
unset "$token_key"
cat "$shift_out"
if grep -F "$token_payload" "$shift_out" >/dev/null; then
  echo "night-shift demo bug: the deploy token leaked into the transcript" >&2
  exit 1
else
  echo "token stayed redacted"
fi

echo "== relational: flagship Secret noninterference lane =="
if jacquard_demo relate "$here/model.jac" --vary secret=night-shift-token --seed 42 \
    --allow eval --allow secret > "$relate_out" 2>&1; then
  :
else
  relate_status=$?
  cat "$relate_out"
  exit "$relate_status"
fi
cat "$relate_out"
if grep -F "rw-secret-v0-" "$relate_out" >/dev/null; then
  echo "night-shift demo bug: a relational payload leaked into the transcript" >&2
  exit 1
else
  echo "secret variation stayed redacted"
fi

awk '/^-- --- demo driver ---$/ { exit } { print }' "$here/model.jac" > "$suite"
printf '\n' >> "$suite"
cat "$here/tests.jac" >> "$suite"

echo "== Warp: pinned schedules, stubbed lever, sampled properties =="
jacquard_demo test "$suite" --seed 42 --no-cache

echo "== Warp: exhaustive proof over all 27 fleet worlds =="
jacquard_demo test "$suite" --seed 42 --no-cache --exhaustive
