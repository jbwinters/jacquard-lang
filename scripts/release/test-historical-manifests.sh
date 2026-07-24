#!/bin/sh
set -eu

usage() {
  echo "usage: test-historical-manifests.sh --commit <commit>" >&2
  exit 2
}

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
checker="$repo_root/scripts/release/check-historical-manifests.sh"
registry_path=scripts/release/historical-publications.tsv
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
mkdir -p "$temp_root/candidate" "$temp_root/pristine"
tar -xf "$temp_root/candidate.tar" -C "$temp_root/candidate"
tar -xf "$temp_root/candidate.tar" -C "$temp_root/pristine"

drift_first_digest() {
  manifest_file=$1
  replacement_file="$manifest_file.mutated"
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
  ' "$manifest_file" >"$replacement_file"
  mv "$replacement_file" "$manifest_file"
}

assert_rejected() {
  rejection_label=$1
  expected_text=$2
  output_file="$temp_root/rejection-output"
  if "$checker" \
    --candidate-root "$temp_root/candidate" \
    --require-history >"$output_file" 2>&1; then
    echo "$rejection_label mutation was accepted" >&2
    exit 1
  fi
  if ! grep -F "$expected_text" "$output_file" >/dev/null; then
    echo "$rejection_label failed without naming $expected_text" >&2
    sed -n '1,120p' "$output_file" >&2
    exit 1
  fi
  echo "$rejection_label rejected"
}

restore_file() {
  relative_path=$1
  cp "$temp_root/pristine/$relative_path" "$temp_root/candidate/$relative_path"
}

"$checker" --candidate-root "$temp_root/candidate" --require-history >/dev/null
echo "clean candidate accepted"

for relative_path in \
  docs/release/effect-linearity/MANIFEST.sha256 \
  docs/release/structured-concurrency/MANIFEST.sha256; do
  drift_first_digest "$temp_root/candidate/$relative_path"
  assert_rejected "$relative_path drift" "$relative_path"
  restore_file "$relative_path"
done

awk -F '\t' '$1 == "ET" || $1 == "GM" { print $3 }' \
  "$temp_root/candidate/$registry_path" |
  while IFS= read -r relative_path; do
    drift_first_digest "$temp_root/candidate/$relative_path"
    assert_rejected "$relative_path drift" "$relative_path"
    restore_file "$relative_path"
  done

extra_manifest=docs/release/effect-taxonomy/UNREGISTERED-MANIFEST.sha256
printf '%064d  README.md\n' 0 >"$temp_root/candidate/$extra_manifest"
assert_rejected "unregistered manifest" "historical manifest inventory does not match"
rm "$temp_root/candidate/$extra_manifest"

missing_manifest=docs/release/governed-membranes/GM1-MANIFEST.sha256
mv \
  "$temp_root/candidate/$missing_manifest" \
  "$temp_root/missing-manifest"
assert_rejected "missing registered manifest" "historical manifest inventory does not match"
mv \
  "$temp_root/missing-manifest" \
  "$temp_root/candidate/$missing_manifest"

coordinated_manifest=docs/release/effect-taxonomy/ET3-MANIFEST.sha256
mv \
  "$temp_root/candidate/$coordinated_manifest" \
  "$temp_root/coordinated-manifest"
awk -F '\t' -v removed="$coordinated_manifest" '$3 != removed { print }' \
  "$temp_root/candidate/$registry_path" \
  >"$temp_root/coordinated-registry"
mv \
  "$temp_root/coordinated-registry" \
  "$temp_root/candidate/$registry_path"
assert_rejected "coordinated manifest and row deletion" "historical registry floor rows drifted"
restore_file "$registry_path"
mv \
  "$temp_root/coordinated-manifest" \
  "$temp_root/candidate/$coordinated_manifest"

specialized_manifest=docs/release/effect-linearity/MANIFEST.sha256
awk -F '\t' -v weakened="$specialized_manifest" '
  BEGIN { OFS = "\t" }
  $3 == weakened {
    $6 = "-"
    $7 = "-"
  }
  { print }
' "$temp_root/candidate/$registry_path" \
  >"$temp_root/weakened-registry"
mv \
  "$temp_root/weakened-registry" \
  "$temp_root/candidate/$registry_path"
assert_rejected "specialized checker policy weakening" "historical registry floor rows drifted"
restore_file "$registry_path"

"$checker" --candidate-root "$temp_root/candidate" --require-history >/dev/null
echo "restored candidate accepted"
