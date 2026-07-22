#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
release_dir="$repo_root/docs/release/governed-membranes"
manifest="$release_dir/MANIFEST.sha256"

for name in DECISION.md CLAIMS.md EVIDENCE.md LIMITS.md REPRO.md MANIFEST.sha256; do
  if [ ! -f "$release_dir/$name" ]; then
    echo "missing governed-membranes release file: $name" >&2
    exit 1
  fi
done

grep -Fq "Deterministic governance for Jacquard's typed Workspace effects" \
  "$release_dir/DECISION.md"
grep -Fq "Do not advertise this work as a production-ready security system" \
  "$release_dir/DECISION.md"
grep -Fq "production security boundary or an operating-system sandbox" \
  "$release_dir/LIMITS.md"
grep -Fq "None of those hashes establishes semantic correctness" \
  "$release_dir/EVIDENCE.md"

for id in 61 62 63 64 65 66 67 68 69 70 71 72 73; do
  count=$(grep -c "^| D$id |" "$release_dir/CLAIMS.md" || true)
  if [ "$count" -ne 1 ]; then
    echo "D$id must have exactly one GM.22 claim row; found $count" >&2
    exit 1
  fi
done

cd "$repo_root"
base=$(sed -n 's/^# Base commit: //p' "$manifest" | head -n 1)
if [ -z "$base" ]; then
  echo "governed-membranes manifest has no base commit" >&2
  exit 1
fi

git_top=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ "$git_top" = "$repo_root" ] && git cat-file -e "$base^{commit}" 2>/dev/null; then
  sha256sum --check --strict "$manifest" >/dev/null
  mkdir -p "$repo_root/.scratch/tmp"
  expected=$(mktemp "$repo_root/.scratch/tmp/gm22-expected.XXXXXX")
  actual=$(mktemp "$repo_root/.scratch/tmp/gm22-actual.XXXXXX")
  trap 'rm -f "$expected" "$actual"' EXIT HUP INT TERM
  {
    git diff --name-only "$base"
    git ls-files --others --exclude-standard
  } |
    sort -u |
    awk '$0 != "docs/release/governed-membranes/MANIFEST.sha256"' >"$expected"
  awk '!/^#/ && NF == 2 {print $2}' "$manifest" | sort -u >"$actual"
  if ! diff -u "$expected" "$actual"; then
    echo "governed-membranes manifest does not cover the complete GM.22 overlay" >&2
    exit 1
  fi
else
  while read -r expected file_path; do
    case "$expected" in
      ''|'#'*) continue ;;
    esac
    if [ ! -f "$file_path" ]; then
      echo "$file_path: missing attested GM.22 file" >&2
      exit 1
    fi
    actual=$(sha256sum "$file_path" | awk '{print $1}')
    if [ "$actual" != "$expected" ]; then
      echo "$file_path: GM.22 hash mismatch: expected $expected, got $actual" >&2
      exit 1
    fi
  done <"$manifest"
fi

echo "governed-membranes GM.22 release pack is complete and byte-consistent"
