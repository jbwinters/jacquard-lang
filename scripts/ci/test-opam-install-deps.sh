#!/usr/bin/env bash

set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
scratch_root=${TMPDIR:-"$repo_root/.scratch/tmp"}
mkdir -p "$scratch_root"
test_root=$(mktemp -d "$scratch_root/opam-install-retry.XXXXXX")
trap 'rm -rf -- "$test_root"' EXIT HUP INT TERM

fake_opam="$test_root/opam"
cat >"$fake_opam" <<'EOF'
#!/usr/bin/env bash
set -eu

count=0
if [ -f "$FAKE_OPAM_COUNT_FILE" ]; then
  count=$(cat "$FAKE_OPAM_COUNT_FILE")
fi
count=$((count + 1))
printf '%s\n' "$count" >"$FAKE_OPAM_COUNT_FILE"
printf '%s\n' "$@" >"$FAKE_OPAM_ARGS_FILE"

if [ "$count" -le "$FAKE_OPAM_FAILURES" ]; then
  exit "${FAKE_OPAM_FAILURE_STATUS:-7}"
fi
EOF
chmod +x "$fake_opam"

count_file="$test_root/count"
args_file="$test_root/args"

FAKE_OPAM_COUNT_FILE="$count_file" \
FAKE_OPAM_ARGS_FILE="$args_file" \
FAKE_OPAM_FAILURES=0 \
OPAM_BIN="$fake_opam" \
OPAM_INSTALL_ATTEMPTS=3 \
OPAM_INSTALL_RETRY_DELAY_SECONDS=0 \
  "$repo_root/scripts/ci/opam-install-deps.sh" \
    --deps-only . "path with space" --with-test -y

test "$(cat "$count_file")" = 1
expected_args=$(printf '<%s>\n' install --deps-only . "path with space" --with-test -y)
actual_args=$(sed 's/^/</; s/$/>/' "$args_file")
test "$actual_args" = "$expected_args"

rm -f "$count_file"
FAKE_OPAM_COUNT_FILE="$count_file" \
FAKE_OPAM_ARGS_FILE="$args_file" \
FAKE_OPAM_FAILURES=2 \
FAKE_OPAM_FAILURE_STATUS=40 \
OPAM_BIN="$fake_opam" \
OPAM_INSTALL_ATTEMPTS=3 \
OPAM_INSTALL_RETRY_DELAY_SECONDS=0 \
  "$repo_root/scripts/ci/opam-install-deps.sh" --deps-only . --with-test -y

test "$(cat "$count_file")" = 3
expected_args=$(printf '<%s>\n' install --deps-only . --with-test -y)
actual_args=$(sed 's/^/</; s/$/>/' "$args_file")
test "$actual_args" = "$expected_args"

rm -f "$count_file"
if FAKE_OPAM_COUNT_FILE="$count_file" \
  FAKE_OPAM_ARGS_FILE="$args_file" \
  FAKE_OPAM_FAILURES=3 \
  FAKE_OPAM_FAILURE_STATUS=40 \
  OPAM_BIN="$fake_opam" \
  OPAM_INSTALL_ATTEMPTS=2 \
  OPAM_INSTALL_RETRY_DELAY_SECONDS=0 \
    "$repo_root/scripts/ci/opam-install-deps.sh" --deps-only .; then
  echo "retry wrapper unexpectedly succeeded after exhausting its attempts" >&2
  exit 1
else
  status=$?
fi

test "$status" = 40
test "$(cat "$count_file")" = 2

rm -f "$count_file"
if FAKE_OPAM_COUNT_FILE="$count_file" \
  FAKE_OPAM_ARGS_FILE="$args_file" \
  FAKE_OPAM_FAILURES=3 \
  FAKE_OPAM_FAILURE_STATUS=31 \
  OPAM_BIN="$fake_opam" \
  OPAM_INSTALL_ATTEMPTS=3 \
  OPAM_INSTALL_RETRY_DELAY_SECONDS=0 \
    "$repo_root/scripts/ci/opam-install-deps.sh" --deps-only .; then
  echo "retry wrapper unexpectedly retried a package-operation failure" >&2
  exit 1
else
  status=$?
fi

test "$status" = 31
test "$(cat "$count_file")" = 1

if OPAM_BIN="$fake_opam" \
  OPAM_INSTALL_ATTEMPTS=0 \
  OPAM_INSTALL_RETRY_DELAY_SECONDS=0 \
    "$repo_root/scripts/ci/opam-install-deps.sh"; then
  echo "retry wrapper accepted an invalid attempt limit" >&2
  exit 1
else
  status=$?
fi
test "$status" = 64

if OPAM_BIN="$fake_opam" \
  OPAM_INSTALL_ATTEMPTS=three \
  OPAM_INSTALL_RETRY_DELAY_SECONDS=0 \
    "$repo_root/scripts/ci/opam-install-deps.sh"; then
  echo "retry wrapper accepted a non-numeric attempt limit" >&2
  exit 1
else
  status=$?
fi
test "$status" = 64

if OPAM_BIN="$fake_opam" \
  OPAM_INSTALL_ATTEMPTS=1 \
  OPAM_INSTALL_RETRY_DELAY_SECONDS=later \
    "$repo_root/scripts/ci/opam-install-deps.sh"; then
  echo "retry wrapper accepted a non-numeric retry delay" >&2
  exit 1
else
  status=$?
fi
test "$status" = 64

rm -f "$count_file"
FAKE_OPAM_COUNT_FILE="$count_file" \
FAKE_OPAM_ARGS_FILE="$args_file" \
FAKE_OPAM_FAILURES=2 \
FAKE_OPAM_FAILURE_STATUS=40 \
OPAM_BIN="$fake_opam" \
OPAM_INSTALL_RETRY_DELAY_SECONDS=0 \
  "$repo_root/scripts/ci/opam-install-deps.sh" --deps-only .

test "$(cat "$count_file")" = 3

echo "opam dependency-install retry policy: ok"
