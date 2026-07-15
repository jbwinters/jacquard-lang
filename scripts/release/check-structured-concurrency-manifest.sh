#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
manifest="$repo_root/docs/release/structured-concurrency/MANIFEST.sha256"

if [ ! -f "$manifest" ]; then
  echo "missing structured-concurrency evidence manifest: $manifest" >&2
  exit 1
fi

cd "$repo_root"
sha256sum --check --strict "$manifest"

base=59b12eb
git_top=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ "$git_top" = "$repo_root" ] && git cat-file -e "$base^{commit}" 2>/dev/null; then
  mkdir -p "$repo_root/.scratch/tmp"
  expected=$(mktemp "$repo_root/.scratch/tmp/sc10-expected.XXXXXX")
  actual=$(mktemp "$repo_root/.scratch/tmp/sc10-actual.XXXXXX")
  trap 'rm -f "$expected" "$actual"' EXIT HUP INT TERM
  {
    git diff --name-only "$base"
    git ls-files --others --exclude-standard
  } |
    sort -u |
    grep -v '^docs/release/effect-linearity/MANIFEST\.sha256$' |
    grep -v '^docs/release/structured-concurrency/MANIFEST\.sha256$' >"$expected"
  awk '!/^#/ && NF == 2 {print $2}' "$manifest" | sort -u >"$actual"
  if ! diff -u "$expected" "$actual"; then
    echo "structured-concurrency manifest does not cover the complete base overlay" >&2
    exit 1
  fi
fi
