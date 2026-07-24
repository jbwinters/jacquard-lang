#!/bin/sh
set -eu

usage() {
  echo "usage: test-historical-manifests.sh --commit <commit>" >&2
  exit 2
}

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
checker="$repo_root/scripts/release/check-historical-manifests.sh"
candidate_commit=

if [ "$#" -eq 2 ] && [ "$1" = "--commit" ]; then
  candidate_commit=$2
else
  usage
fi

cd "$repo_root"
candidate_oid=$(git rev-parse --verify "$candidate_commit^{commit}" 2>/dev/null) || {
  echo "candidate commit is unavailable: $candidate_commit" >&2
  exit 1
}
if [ -n "${GITHUB_SHA:-}" ]; then
  github_oid=$(git rev-parse --verify "$GITHUB_SHA^{commit}" 2>/dev/null) || {
    echo "GITHUB_SHA is unavailable: $GITHUB_SHA" >&2
    exit 1
  }
  if [ "$candidate_oid" != "$github_oid" ]; then
    echo "candidate commit $candidate_oid does not match GITHUB_SHA $github_oid" >&2
    exit 1
  fi
fi

umask 077
mkdir -p "$repo_root/.scratch/tmp"
temp_root=$(mktemp -d "$repo_root/.scratch/tmp/historical-manifest-test.XXXXXX")
cleanup() {
  rm -rf -- "$temp_root"
}
trap cleanup EXIT HUP INT TERM

git archive --format=tar --output="$temp_root/candidate.tar" "$candidate_oid"
mkdir -p "$temp_root/el" "$temp_root/sc"
tar -xf "$temp_root/candidate.tar" -C "$temp_root/el"
tar -xf "$temp_root/candidate.tar" -C "$temp_root/sc"

drift_first_digest() {
  manifest=$1
  replacement="$manifest.mutated"
  awk '
    BEGIN { changed = 0 }
    !changed && $0 !~ /^#/ && NF == 2 {
      printf "%064d  %s\n", 0, $2
      changed = 1
      next
    }
    { print }
    END {
      if (!changed)
        exit 1
    }
  ' "$manifest" >"$replacement"
  mv "$replacement" "$manifest"
}

assert_rejected() {
  label=$1
  root=$2
  if "$checker" --candidate-root "$root" --require-history >/dev/null 2>&1; then
    echo "$label manifest drift was accepted" >&2
    exit 1
  fi
  echo "$label manifest drift rejected"
}

drift_first_digest "$temp_root/el/docs/release/effect-linearity/MANIFEST.sha256"
assert_rejected EL "$temp_root/el"

drift_first_digest "$temp_root/sc/docs/release/structured-concurrency/MANIFEST.sha256"
assert_rejected SC "$temp_root/sc"
