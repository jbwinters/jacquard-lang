#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
release_dir="$repo_root/docs/release/governed-membranes"
manifest="$release_dir/GM21-MANIFEST.sha256"
gm22_manifest="$release_dir/MANIFEST.sha256"
predecessor="d3eaa9b92659fb595def64025a2434d6898e5274"

if [ ! -f "$manifest" ]; then
  echo "missing GM.21 manifest: $manifest" >&2
  exit 1
fi

base=$(sed -n 's/^# Base commit: //p' "$manifest" | head -n 1)
if [ "$base" != "$predecessor" ]; then
  echo "GM.21 must name exact predecessor $predecessor; found ${base:-none}" >&2
  exit 1
fi

cd "$repo_root"
mkdir -p "$repo_root/.scratch/tmp"

predecessor_tree=
expected_inventory=
actual_inventory=
cleanup() {
  if [ -n "$predecessor_tree" ]; then
    rm -rf -- "$predecessor_tree"
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
    echo "missing predecessor attestation anchor: $path" >&2
    exit 1
  fi
  actual=$(sha256sum "$path" | awk '{print $1}')
  if [ "$actual" != "$expected" ]; then
    echo "$path: predecessor attestation anchor changed: expected $expected, got $actual" >&2
    exit 1
  fi
}

check_anchor \
  9cbd7bcdd2e9065d1f11855a9d71b8ff854873711958fa56a045da55504af11b \
  docs/release/governed-membranes/GM19-MANIFEST.sha256
check_anchor \
  55d93994fe84f6b78b8da7279eb24d34c2e43dc7ca3644242b5f91d42189d594 \
  docs/release/governed-membranes/MANIFEST.sha256
check_anchor \
  8101e9c8fa185ea58822bf36cc494767d5b95f1d2a7ccbf7e2a8469c70a1ec42 \
  scripts/release/check-governed-membranes-manifest.sh

sha256sum --check --strict "$manifest" >/dev/null

git_top=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -n "$git_top" ]; then
  if ! git -C "$git_top" cat-file -e "$predecessor^{commit}" 2>/dev/null; then
    echo "Git history is present but lacks GM.21 predecessor $predecessor; fetch full history" >&2
    exit 1
  fi
  if ! git -C "$git_top" merge-base --is-ancestor "$predecessor" HEAD; then
    echo "GM.21 predecessor $predecessor is not an ancestor of HEAD" >&2
    exit 1
  fi
  predecessor_tree=$(mktemp -d "$repo_root/.scratch/tmp/gm21-predecessor.XXXXXX")
  git -C "$git_top" archive --format=tar --output="$predecessor_tree/source.tar" "$predecessor"
  mkdir -p "$predecessor_tree/source"
  tar -xf "$predecessor_tree/source.tar" -C "$predecessor_tree/source"
  "$predecessor_tree/source/scripts/release/check-governed-membranes-manifest.sh" >/dev/null
else
  case "$repo_root" in
    */_build/.sandbox/*/default) dune_cram_sandbox=1 ;;
    *) dune_cram_sandbox=0 ;;
  esac
  while read -r historical_hash path; do
    case "$historical_hash" in
      ''|'#'*) continue ;;
    esac
    if awk -v path="$path" '!/^#/ && NF == 2 && $2 == path { found = 1 } END { exit !found }' \
      "$manifest"
    then
      continue
    fi
    if [ ! -f "$path" ]; then
      if [ "$dune_cram_sandbox" -eq 1 ] && [ "$path" = ".github/workflows/ci.yml" ]; then
        continue
      fi
      echo "$path: missing retained GM.22 file in source archive" >&2
      exit 1
    fi
    current_hash=$(sha256sum "$path" | awk '{print $1}')
    if [ "$current_hash" != "$historical_hash" ]; then
      echo "$path: differs from GM.22 and is not superseded by GM.21" >&2
      exit 1
    fi
  done <"$gm22_manifest"
  echo "note: historical reconstruction unavailable; verified retained GM.22 files and pinned attestations" >&2
fi

if [ "$git_top" = "$repo_root" ]; then
  expected_inventory=$(mktemp "$repo_root/.scratch/tmp/gm21-expected.XXXXXX")
  actual_inventory=$(mktemp "$repo_root/.scratch/tmp/gm21-actual.XXXXXX")
  {
    git -c core.quotePath=false diff --no-renames --name-only "$predecessor"
    git ls-files --others --exclude-standard
  } |
    sort -u |
    awk '$0 != "docs/release/governed-membranes/GM21-MANIFEST.sha256"' >"$expected_inventory"
  awk '!/^#/ && NF == 2 {print $2}' "$manifest" | sort -u >"$actual_inventory"
  if ! diff -u "$expected_inventory" "$actual_inventory"; then
    echo "GM.21 manifest does not cover the complete successor overlay" >&2
    exit 1
  fi
fi

echo "GM.19/GM.22 predecessor attestations are preserved and byte-consistent"
echo "GM.21 successor release pack is complete and byte-consistent"
