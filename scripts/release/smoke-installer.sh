#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT"
: "${TMPDIR:=$ROOT/.scratch/tmp}"
export TMPDIR
mkdir -p "$TMPDIR"

target=${1:-linux-x86_64}
case "$target" in
  linux-x86_64) expected_platform=yes ;;
  *) expected_platform=no ;;
esac

work=$(mktemp -d "$TMPDIR/jacquard-installer-smoke.XXXXXX")
trap 'rm -rf "$work"' EXIT

JACQUARD_DIST_DIR="$work/dist" scripts/release/package-binary.sh "$target" >/dev/null
archive="$work/dist/jacquard-$target.tar.gz"
prefix="$work/prefix"

JACQUARD_INSTALL_TARGET="$target" \
JACQUARD_INSTALL_URL="file://$archive" \
JACQUARD_INSTALL_PREFIX="$prefix" \
  sh scripts/install.sh >/dev/null

test "$("$prefix/bin/jacquard" --version)" = "0.1.0"
test "$("$prefix/bin/jac" --version)" = "0.1.0"
test "$("$prefix/bin/jac" run "$prefix/share/jacquard/demos/basics/m1-fact.jac")" = "120"
scripts/release/smoke-packaged-demos.sh "$prefix"

if [ "$expected_platform" = yes ]; then
  bad="$work/bad"
  mkdir -p "$bad"
  cp "$archive" "$bad/jacquard-$target.tar.gz"
  printf '%064d  jacquard-%s.tar.gz\n' 0 "$target" >"$bad/jacquard-$target.tar.gz.sha256"
  if JACQUARD_INSTALL_TARGET="$target" \
    JACQUARD_INSTALL_URL="file://$bad/jacquard-$target.tar.gz" \
    JACQUARD_INSTALL_PREFIX="$work/rejected" \
      sh scripts/install.sh >"$work/bad.stdout" 2>"$work/bad.stderr"
  then
    echo "installer accepted a corrupted checksum" >&2
    exit 1
  fi
  test ! -e "$work/rejected/bin/jacquard"
fi

echo "installer smoke: PASS ($target)"
