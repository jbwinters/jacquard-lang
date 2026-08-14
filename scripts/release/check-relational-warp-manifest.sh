#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
release_dir="$repo_root/docs/release/relational-warp"
manifest="$release_dir/RW7-MANIFEST.sha256"
predecessor="10e27f4bb534f275959c253b02a40cb9d87f92b0"

if [ ! -f "$manifest" ]; then
  echo "missing RW.7 manifest: $manifest" >&2
  exit 1
fi

base=$(sed -n 's/^# Base commit: //p' "$manifest" | head -n 1)
if [ "$base" != "$predecessor" ]; then
  echo "RW.7 must name exact predecessor $predecessor; found ${base:-none}" >&2
  exit 1
fi

cd "$repo_root"
mkdir -p "$repo_root/.scratch/tmp"

expected_inventory=
actual_inventory=
cleanup() {
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
    echo "missing RW.7 historical attestation anchor: $path" >&2
    exit 1
  fi
  actual=$(sha256sum "$path" | awk '{print $1}')
  if [ "$actual" != "$expected" ]; then
    echo "$path: RW.7 historical anchor changed: expected $expected, got $actual" >&2
    exit 1
  fi
}

check_anchor \
  c36a9a52b9fd33f8c7e3b91d69b6da2cc6169529f52755f3d5664824994abbca \
  scripts/release/historical-publications.tsv
check_anchor \
  fca83b064c164489ee818f60c7e45668b819ecbb95c94db1abf8cad1ea191d2e \
  scripts/release/check-historical-manifests.sh
check_anchor \
  dd597d01e8d806fa8d962db419ca23ecb16031989526dd3ee01b130567eb6c50 \
  docs/release/structured-concurrency/SC17-MANIFEST.sha256
check_anchor \
  4e35e42c06b251d9caefb34970f7d66cd5aca58c4f4caaa342efb20045e036ae \
  scripts/release/check-sc17-manifest.sh

sha256sum --check --strict "$manifest" >/dev/null

git_top=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ "$git_top" = "$repo_root" ]; then
  if ! git cat-file -e "$predecessor^{commit}" 2>/dev/null; then
    echo "Git history is present but lacks RW.7 predecessor $predecessor; fetch full history" >&2
    exit 1
  fi
  if ! git merge-base --is-ancestor "$predecessor" HEAD; then
    echo "RW.7 predecessor $predecessor is not an ancestor of HEAD" >&2
    exit 1
  fi

  expected_inventory=$(mktemp "$repo_root/.scratch/tmp/rw7-expected.XXXXXX")
  actual_inventory=$(mktemp "$repo_root/.scratch/tmp/rw7-actual.XXXXXX")
  {
    git -c core.quotePath=false diff --no-renames --name-only "$predecessor"
    git ls-files --others --exclude-standard
  } |
    sort -u |
    awk '$0 != "docs/release/relational-warp/RW7-MANIFEST.sha256"' \
      >"$expected_inventory"
  awk '!/^#/ && NF == 2 {print $2}' "$manifest" | sort -u >"$actual_inventory"
  if ! diff -u "$expected_inventory" "$actual_inventory"; then
    echo "RW.7 manifest does not cover the complete successor overlay" >&2
    exit 1
  fi
else
  echo "note: Git history unavailable; verified RW.7 anchors and overlay hashes" >&2
fi

echo "Historical manifest policy and SC.17 anchors are preserved"
echo "RW.7 relational regression pack is complete and byte-consistent"
