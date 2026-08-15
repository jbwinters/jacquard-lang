#!/bin/sh
set -eu

usage() {
  echo "usage: check-0.2-manifest.sh --commit <commit>" >&2
  exit 2
}

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
base=${JACQUARD_RELEASE_BASE:-c0f570501b751865c0c0584d9b15be08b6ec1cde}
manifest_path=docs/release/0.2/MANIFEST.sha256

if [ "$#" -ne 2 ] || [ "$1" != "--commit" ]; then
  usage
fi

cd "$repo_root"
candidate_oid=$(git rev-parse --verify "$2^{commit}" 2>/dev/null) || {
  echo "candidate commit is unavailable: $2" >&2
  exit 1
}
base_oid=$(git rev-parse --verify "$base^{commit}" 2>/dev/null) || {
  echo "release base commit is unavailable: $base" >&2
  exit 1
}
git merge-base --is-ancestor "$base_oid" "$candidate_oid" || {
  echo "release base $base_oid is not an ancestor of candidate $candidate_oid" >&2
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
temp_root=$(mktemp -d "$repo_root/.scratch/tmp/release-0.2-manifest.XXXXXX")
cleanup() {
  rm -rf -- "$temp_root"
}
trap cleanup EXIT HUP INT TERM

git show "$candidate_oid:$manifest_path" >"$temp_root/manifest" 2>/dev/null || {
  echo "candidate manifest is unavailable: $manifest_path" >&2
  exit 1
}

LC_ALL=C awk -v manifest="$manifest_path" '
  function fail(message) {
    print "invalid 0.2 manifest at line " NR ": " message > "/dev/stderr"
    exit 1
  }
  NF != 2 { fail("expected SHA-256 and path") }
  length($1) != 64 || $1 !~ /^[0-9a-f]+$/ { fail("malformed SHA-256") }
  $2 !~ /^[A-Za-z0-9._\/-]+$/ || $2 ~ /^\// || $2 ~ /(^|\/)\.\.($|\/)/ {
    fail("unsafe path " $2)
  }
  $2 == manifest { fail("manifest must not hash itself") }
  seen[$2]++ { fail("duplicate path " $2) }
  previous != "" && $2 <= previous { fail("paths are not strictly sorted") }
  { previous = $2 }
  END { if (NR == 0) fail("manifest is empty") }
' "$temp_root/manifest"

awk '{ print $2 }' "$temp_root/manifest" >"$temp_root/manifest-paths"
{
  cat "$temp_root/manifest-paths"
  printf '%s\n' "$manifest_path"
} | LC_ALL=C sort >"$temp_root/expected-paths"
git diff --name-only "$base_oid..$candidate_oid" | LC_ALL=C sort >"$temp_root/actual-paths"

if ! cmp -s "$temp_root/expected-paths" "$temp_root/actual-paths"; then
  echo "0.2 manifest inventory does not match the complete release change set" >&2
  diff -u "$temp_root/expected-paths" "$temp_root/actual-paths" >&2 || true
  exit 1
fi

while read -r expected_sha rel_path extra; do
  if [ -n "${extra:-}" ]; then
    echo "invalid manifest record for $rel_path" >&2
    exit 1
  fi
  if [ "$(git cat-file -t "$candidate_oid:$rel_path" 2>/dev/null || true)" != blob ]; then
    echo "manifest path is not a regular Git blob: $rel_path" >&2
    exit 1
  fi
  actual_sha=$(git show "$candidate_oid:$rel_path" | sha256sum | awk '{ print $1 }')
  if [ "$actual_sha" != "$expected_sha" ]; then
    echo "0.2 manifest mismatch: $rel_path" >&2
    echo "expected $expected_sha" >&2
    echo "actual   $actual_sha" >&2
    exit 1
  fi
done <"$temp_root/manifest"

echo "0.2 release manifest verified for $candidate_oid against $base_oid"
