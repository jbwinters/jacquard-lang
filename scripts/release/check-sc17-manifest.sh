#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
release_dir="$repo_root/docs/release/structured-concurrency"
manifest="$release_dir/SC17-MANIFEST.sha256"
predecessor="0783845027a392fe59087534cd6b147ccff2b123"
publication="81c14506e0d099dabe04a40b00c1d4fc45b42d47"

if [ ! -f "$manifest" ]; then
  echo "missing SC.17 manifest: $manifest" >&2
  exit 1
fi

base=$(sed -n 's/^# Base commit: //p' "$manifest" | head -n 1)
if [ "$base" != "$predecessor" ]; then
  echo "SC.17 must name exact predecessor $predecessor; found ${base:-none}" >&2
  exit 1
fi

cd "$repo_root"
mkdir -p "$repo_root/.scratch/tmp"

sc_historical_tree=
gm_historical_tree=
expected_inventory=
actual_inventory=
cleanup() {
  if [ -n "$sc_historical_tree" ]; then
    rm -rf -- "$sc_historical_tree"
  fi
  if [ -n "$gm_historical_tree" ]; then
    rm -rf -- "$gm_historical_tree"
  fi
  if [ -n "$expected_inventory" ]; then
    rm -f -- "$expected_inventory"
  fi
  if [ -n "$actual_inventory" ]; then
    rm -f -- "$actual_inventory"
  fi
}
trap cleanup EXIT HUP INT TERM

check_anchor() {
  expected=$1
  path=$2
  if [ ! -f "$path" ]; then
    echo "missing historical SC.16 attestation anchor: $path" >&2
    exit 1
  fi
  actual=$(sha256sum "$path" | awk '{print $1}')
  if [ "$actual" != "$expected" ]; then
    echo "$path: historical SC.16 anchor changed: expected $expected, got $actual" >&2
    exit 1
  fi
}

check_anchor \
  3ca69edb0121713deb211042dfe2099bbd425c05292789d46a5db00e4d52ffd9 \
  docs/release/structured-concurrency/MANIFEST.sha256
check_anchor \
  d0b40d94343a06343f08dbcf2a11c7b11fcf8a465df4e3375b4bfd703b62a495 \
  scripts/release/check-structured-concurrency-manifest.sh
check_anchor \
  19603651590eb6de890a7e3597b009403f03234d6d5f022b076497d8a638e45f \
  docs/release/governed-membranes/GM21-MANIFEST.sha256
check_anchor \
  14fcc2ec9274d1dde793ef534591c4d757934089d0510424e52187e9b0fd5a82 \
  scripts/release/check-gm21-manifest.sh

sha256sum --check --strict "$manifest" >/dev/null

git_top=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ "$git_top" = "$repo_root" ]; then
  if ! git cat-file -e "$predecessor^{commit}" 2>/dev/null; then
    echo "Git history is present but lacks SC.17 predecessor $predecessor; fetch full history" >&2
    exit 1
  fi
  if ! git cat-file -e "$publication^{commit}" 2>/dev/null; then
    echo "Git history is present but lacks SC.16 publication $publication; fetch full history" >&2
    exit 1
  fi
  if ! git merge-base --is-ancestor "$predecessor" HEAD; then
    echo "SC.17 predecessor $predecessor is not an ancestor of HEAD" >&2
    exit 1
  fi

  sc_historical_tree=$(mktemp -d "$repo_root/.scratch/tmp/sc17-sc16.XXXXXX")
  git archive --format=tar --output="$sc_historical_tree/source.tar" "$publication"
  mkdir -p "$sc_historical_tree/source"
  tar -xf "$sc_historical_tree/source.tar" -C "$sc_historical_tree/source"
  (
    cd "$sc_historical_tree/source"
    GIT_DIR=/nonexistent scripts/release/check-structured-concurrency-manifest.sh >/dev/null 2>&1
  )

  gm_historical_tree=$(mktemp -d "$repo_root/.scratch/tmp/sc17-gm21.XXXXXX")
  git archive --format=tar --output="$gm_historical_tree/source.tar" "$predecessor"
  mkdir -p "$gm_historical_tree/source"
  tar -xf "$gm_historical_tree/source.tar" -C "$gm_historical_tree/source"
  (
    cd "$gm_historical_tree/source"
    GIT_DIR=/nonexistent scripts/release/check-gm21-manifest.sh >/dev/null 2>&1
  )

  expected_inventory=$(mktemp "$repo_root/.scratch/tmp/sc17-expected.XXXXXX")
  actual_inventory=$(mktemp "$repo_root/.scratch/tmp/sc17-actual.XXXXXX")
  {
    git -c core.quotePath=false diff --no-renames --name-only "$predecessor"
    git ls-files --others --exclude-standard
  } |
    sort -u |
    awk '$0 != "docs/release/structured-concurrency/SC17-MANIFEST.sha256"' \
      >"$expected_inventory"
  awk '!/^#/ && NF == 2 {print $2}' "$manifest" | sort -u >"$actual_inventory"
  if ! diff -u "$expected_inventory" "$actual_inventory"; then
    echo "SC.17 manifest does not cover the complete successor overlay" >&2
    exit 1
  fi
else
  echo "note: historical reconstructions unavailable; verified pinned SC.16/GM.21 attestations and SC.17 overlay" >&2
fi

echo "SC.16 and GM.21 historical attestations are preserved and byte-consistent"
echo "SC.17 cancellation correction pack is complete and byte-consistent"
