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

base=$(sed -n 's/^# Base commit: //p' "$manifest" | head -n 1)
if [ -z "$base" ]; then
  echo "structured-concurrency manifest has no base commit" >&2
  exit 1
fi
if git cat-file -e "$base^{commit}" 2>/dev/null; then
  mkdir -p "$repo_root/.scratch/tmp"
  expected=$(mktemp "$repo_root/.scratch/tmp/sc4-expected.XXXXXX")
  actual=$(mktemp "$repo_root/.scratch/tmp/sc4-actual.XXXXXX")
  trap 'rm -f "$expected" "$actual"' EXIT HUP INT TERM
  {
    git diff --name-only "$base"
    git ls-files --others --exclude-standard
  } |
    sort -u |
    awk '!/MANIFEST\.sha256$/ {print}' |
    while IFS= read -r file_path; do
      if [ -f "$file_path" ]; then
        printf '%s\n' "$file_path"
      fi
    done >"$expected"
  awk '!/^#/ && NF == 2 {print $2}' "$manifest" | sort -u >"$actual"
  if ! diff -u "$expected" "$actual"; then
    echo "structured-concurrency manifest does not cover the complete base overlay" >&2
    exit 1
  fi
fi
