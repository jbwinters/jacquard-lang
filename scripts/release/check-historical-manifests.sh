#!/bin/sh
set -eu

# CI attests immutable publication objects, not the mutable runner worktree.
# The candidate supplies an owner-reviewed, append-only registry and must retain
# every registered manifest/checker byte. Each manifest is then checked inside
# its exact publication tree. --candidate-root is a mutation-test seam only.

usage() {
  cat >&2 <<'EOF'
usage:
  check-historical-manifests.sh --commit <commit> --require-history
  check-historical-manifests.sh --candidate-root <directory> --require-history
EOF
  exit 2
}

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
candidate_commit=
candidate_root=
require_history=false
registry_path=scripts/release/historical-publications.tsv
# Append "<evidence-pack commit> <SHA-256 of its complete registry-row subset>";
# never remove or replace a floor.
registry_floor_records='4c92482ca0e5a513c3e3cdf873fb78d51131ded9 c36a9a52b9fd33f8c7e3b91d69b6da2cc6169529f52755f3d5664824994abbca'

while [ "$#" -gt 0 ]; do
  case "$1" in
    --commit)
      [ "$#" -ge 2 ] || usage
      [ -z "$candidate_commit$candidate_root" ] || usage
      candidate_commit=$2
      shift 2
      ;;
    --candidate-root)
      [ "$#" -ge 2 ] || usage
      [ -z "$candidate_commit$candidate_root" ] || usage
      candidate_root=$2
      shift 2
      ;;
    --require-history)
      require_history=true
      shift
      ;;
    *)
      usage
      ;;
  esac
done

[ -n "$candidate_commit$candidate_root" ] || usage
if [ "$require_history" != true ]; then
  echo "--require-history is mandatory for release attestation" >&2
  exit 2
fi

umask 077
mkdir -p "$repo_root/.scratch/tmp"
temp_root=$(mktemp -d "$repo_root/.scratch/tmp/historical-manifests.XXXXXX")
cleanup() {
  rm -rf -- "$temp_root"
}
trap cleanup EXIT HUP INT TERM

cd "$repo_root"
git_top=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ "$git_top" != "$repo_root" ]; then
  echo "history-backed release attestation requires this repository's Git history" >&2
  exit 1
fi

resolve_commit() {
  requested_commit=$1
  git rev-parse --verify "$requested_commit^{commit}" 2>/dev/null
}

archive_commit() {
  requested_commit=$1
  destination=$2
  archive=$3
  mkdir -p "$destination"
  git archive --format=tar --output="$archive" "$requested_commit"
  tar -xf "$archive" -C "$destination"
}

if [ -n "$candidate_commit" ]; then
  candidate_oid=$(resolve_commit "$candidate_commit") || {
    echo "candidate commit is unavailable: $candidate_commit" >&2
    exit 1
  }
  if [ -n "${GITHUB_SHA:-}" ]; then
    github_oid=$(resolve_commit "$GITHUB_SHA") || {
      echo "GITHUB_SHA is unavailable: $GITHUB_SHA" >&2
      exit 1
    }
    if [ "$candidate_oid" != "$github_oid" ]; then
      echo "candidate commit $candidate_oid does not match GITHUB_SHA $github_oid" >&2
      exit 1
    fi
  fi
  candidate_root="$temp_root/candidate"
  archive_commit "$candidate_oid" "$candidate_root" "$temp_root/candidate.tar"
else
  candidate_root=$(CDPATH= cd -- "$candidate_root" 2>/dev/null && pwd) || {
    echo "candidate root is unavailable: $candidate_root" >&2
    exit 1
  }
fi

registry_file="$candidate_root/$registry_path"
if [ ! -f "$registry_file" ] || [ -L "$registry_file" ]; then
  echo "historical publication registry is missing or not regular: $registry_path" >&2
  exit 1
fi

# Validate the candidate's policy surface before reconstructing any history.
LC_ALL=C awk -F '\t' '
  function fail(message) {
    print "invalid historical publication registry at line " NR ": " message > "/dev/stderr"
    exit 1
  }
  NF != 7 { fail("expected seven tab-separated fields") }
  $1 !~ /^(EL|ET|GM|SC)$/ { fail("unknown family " $1) }
  $2 !~ /^[A-Z][A-Z0-9]*$/ { fail("unsafe or empty label " $2) }
  length($4) != 40 || $4 !~ /^[0-9a-f]+$/ { fail("malformed publication commit") }
  length($5) != 64 || $5 !~ /^[0-9a-f]+$/ { fail("malformed manifest hash") }
  $3 !~ /^docs\/release\/[a-z0-9-]+\/[A-Z0-9-]+\.sha256$/ {
    fail("unsafe manifest path " $3)
  }
  $1 == "EL" && $3 !~ /^docs\/release\/effect-linearity\// {
    fail("EL path is outside effect-linearity")
  }
  $1 == "ET" && $3 !~ /^docs\/release\/effect-taxonomy\// {
    fail("ET path is outside effect-taxonomy")
  }
  $1 == "GM" && $3 !~ /^docs\/release\/governed-membranes\// {
    fail("GM path is outside governed-membranes")
  }
  $1 == "SC" && $3 !~ /^docs\/release\/structured-concurrency\// {
    fail("SC path is outside structured-concurrency")
  }
  ($6 == "-") != ($7 == "-") { fail("checker path and hash must be paired") }
  $6 != "-" && $6 !~ /^scripts\/release\/check-[a-z0-9-]+\.sh$/ {
    fail("unsafe checker path " $6)
  }
  $7 != "-" && (length($7) != 64 || $7 !~ /^[0-9a-f]+$/) {
    fail("malformed checker hash")
  }
  seen_label[$1 SUBSEP $2]++ { fail("duplicate family/label " $1 "/" $2) }
  seen_manifest[$3]++ { fail("duplicate manifest path " $3) }
  previous != "" && $3 <= previous { fail("manifest paths are not strictly sorted") }
  { previous = $3 }
  END { if (NR == 0) fail("registry is empty") }
' "$registry_file"

cut -f3 "$registry_file" | LC_ALL=C sort >"$temp_root/registered-manifests"
{
  find \
    "$candidate_root/docs/release/effect-linearity" \
    -mindepth 1 -maxdepth 1 -name '*.sha256' \
    -printf 'docs/release/effect-linearity/%f\n'
  find \
    "$candidate_root/docs/release/effect-taxonomy" \
    -mindepth 1 -maxdepth 1 -name '*.sha256' \
    -printf 'docs/release/effect-taxonomy/%f\n'
  find \
    "$candidate_root/docs/release/governed-membranes" \
    -mindepth 1 -maxdepth 1 -name '*.sha256' \
    -printf 'docs/release/governed-membranes/%f\n'
  find \
    "$candidate_root/docs/release/structured-concurrency" \
    -mindepth 1 -maxdepth 1 -name '*.sha256' \
    -printf 'docs/release/structured-concurrency/%f\n'
} | LC_ALL=C sort >"$temp_root/candidate-manifests"
if ! cmp -s "$temp_root/registered-manifests" "$temp_root/candidate-manifests"; then
  echo "historical manifest inventory does not match the registry" >&2
  diff -u "$temp_root/registered-manifests" "$temp_root/candidate-manifests" >&2 || true
  exit 1
fi

: >"$temp_root/floor-manifest-hashes-raw"
previous_floor_oid=
printf '%s\n' "$registry_floor_records" >"$temp_root/registry-floor-records"
while IFS=' ' read -r registry_floor_commit expected_floor_rows_sha floor_extra; do
  if [ -n "$floor_extra" ] ||
    [ "${#expected_floor_rows_sha}" -ne 64 ] ||
    ! printf '%s\n' "$expected_floor_rows_sha" | grep -Eq '^[0-9a-f]+$'; then
    echo "historical registry floor record is malformed" >&2
    exit 1
  fi
  registry_floor_oid=$(resolve_commit "$registry_floor_commit") || {
    echo "historical registry floor commit is unavailable: $registry_floor_commit" >&2
    exit 1
  }
  if [ -n "$previous_floor_oid" ] &&
    ! git merge-base --is-ancestor "$previous_floor_oid" "$registry_floor_oid"; then
    echo "historical registry floors are not an ancestor chain" >&2
    exit 1
  fi
  if [ -n "$candidate_commit" ] &&
    ! git merge-base --is-ancestor "$registry_floor_oid" "$candidate_oid"; then
    echo "historical registry floor $registry_floor_oid is not an ancestor of candidate $candidate_oid" >&2
    exit 1
  fi

  git ls-tree -r --name-only \
    "$registry_floor_oid" \
    docs/release/effect-linearity \
    docs/release/effect-taxonomy \
    docs/release/governed-membranes \
    docs/release/structured-concurrency \
    >"$temp_root/floor-tree"
  LC_ALL=C awk -F / 'NF == 4 && $4 ~ /\.sha256$/ { print }' \
    "$temp_root/floor-tree" \
    >"$temp_root/floor-manifests-unsorted"
  LC_ALL=C sort \
    "$temp_root/floor-manifests-unsorted" \
    >"$temp_root/floor-manifests"
  while IFS= read -r floor_manifest; do
    floor_sha=$(
      git show "$registry_floor_oid:$floor_manifest" |
      sha256sum |
      awk '{print $1}'
    )
    printf '%s\t%s\n' "$floor_manifest" "$floor_sha"
  done <"$temp_root/floor-manifests" >>"$temp_root/floor-manifest-hashes-raw"

  LC_ALL=C awk -F '\t' '
    NR == FNR {
      floor_path[$1] = 1
      next
    }
    $3 in floor_path { print }
  ' "$temp_root/floor-manifests" "$registry_file" \
    >"$temp_root/floor-registry-rows"
  actual_floor_rows_sha=$(
    sha256sum "$temp_root/floor-registry-rows" |
    awk '{print $1}'
  )
  if [ "$actual_floor_rows_sha" != "$expected_floor_rows_sha" ]; then
    echo "historical registry floor rows drifted for $registry_floor_oid" >&2
    echo "expected $expected_floor_rows_sha" >&2
    echo "actual   $actual_floor_rows_sha" >&2
    exit 1
  fi
  previous_floor_oid=$registry_floor_oid
done <"$temp_root/registry-floor-records"
LC_ALL=C awk -F '\t' '
  seen[$1] && retained_hash[$1] != $2 {
    print "historical registry floors disagree for " $1 > "/dev/stderr"
    failed = 1
  }
  !seen[$1] { print }
  {
    seen[$1] = 1
    retained_hash[$1] = $2
  }
  END { exit failed }
' "$temp_root/floor-manifest-hashes-raw" >"$temp_root/floor-manifest-hashes-unique"
LC_ALL=C sort \
  "$temp_root/floor-manifest-hashes-unique" \
  >"$temp_root/floor-manifest-hashes"
LC_ALL=C awk -F '\t' '
  NR == FNR {
    registered_hash[$3] = $5
    next
  }
  !($1 in registered_hash) {
    print "historical registry floor manifest is no longer registered: " $1 > "/dev/stderr"
    failed = 1
    next
  }
  registered_hash[$1] != $2 {
    print "historical registry floor hash drifted: " $1 > "/dev/stderr"
    failed = 1
  }
  END { exit failed }
' "$registry_file" "$temp_root/floor-manifest-hashes"

check_retained_file() {
  retained_label=$1
  expected_sha=$2
  relative_path=$3
  retained_file="$candidate_root/$relative_path"
  if [ ! -f "$retained_file" ] || [ -L "$retained_file" ]; then
    echo "$retained_label retained file is missing or not regular: $relative_path" >&2
    exit 1
  fi
  actual_sha=$(sha256sum "$retained_file" | awk '{print $1}')
  if [ "$actual_sha" != "$expected_sha" ]; then
    echo "$retained_label retained file drifted: $relative_path" >&2
    echo "expected $expected_sha" >&2
    echo "actual   $actual_sha" >&2
    exit 1
  fi
}

# Complete all cheap candidate-byte checks before any publication archive work.
while IFS="$(printf '\t')" read -r family label manifest_path publication manifest_sha checker_path checker_sha; do
  check_retained_file "$label manifest" "$manifest_sha" "$manifest_path"
  if [ "$checker_path" != "-" ]; then
    check_retained_file "$label checker" "$checker_sha" "$checker_path"
  fi
done <"$registry_file"

mkdir -p "$temp_root/publications" "$temp_root/archives"
while IFS="$(printf '\t')" read -r family label manifest_path publication manifest_sha checker_path checker_sha; do
  publication_oid=$(resolve_commit "$publication") || {
    echo "$label publication commit is unavailable: $publication" >&2
    exit 1
  }
  if [ -n "$candidate_commit" ]; then
    if ! git merge-base --is-ancestor "$publication_oid" "$candidate_oid"; then
      echo "$label publication $publication_oid is not an ancestor of candidate $candidate_oid" >&2
      exit 1
    fi
    last_manifest_commit=$(git log -1 --format=%H "$candidate_oid" -- "$manifest_path")
    if [ "$last_manifest_commit" != "$publication_oid" ]; then
      echo "$label registry publication is not the last commit changing $manifest_path" >&2
      echo "registered $publication_oid" >&2
      echo "last       $last_manifest_commit" >&2
      exit 1
    fi
  fi

  publication_root="$temp_root/publications/$publication_oid"
  if [ ! -d "$publication_root" ]; then
    archive_commit \
      "$publication_oid" \
      "$publication_root" \
      "$temp_root/archives/$publication_oid.tar"
  fi

  publication_manifest="$publication_root/$manifest_path"
  if [ ! -f "$publication_manifest" ] || [ -L "$publication_manifest" ]; then
    echo "$label publication manifest is missing or not regular: $manifest_path" >&2
    exit 1
  fi
  publication_manifest_sha=$(sha256sum "$publication_manifest" | awk '{print $1}')
  if [ "$publication_manifest_sha" != "$manifest_sha" ]; then
    echo "$label publication manifest does not match its pinned byte identity" >&2
    exit 1
  fi
  (
    cd "$publication_root"
    sha256sum --check --strict "$manifest_path" >/dev/null
  )

  if [ "$checker_path" != "-" ]; then
    publication_checker="$publication_root/$checker_path"
    if [ ! -f "$publication_checker" ] || [ -L "$publication_checker" ]; then
      echo "$label publication checker is missing or not regular: $checker_path" >&2
      exit 1
    fi
    publication_checker_sha=$(sha256sum "$publication_checker" | awk '{print $1}')
    if [ "$publication_checker_sha" != "$checker_sha" ]; then
      echo "$label publication checker does not match its pinned byte identity" >&2
      exit 1
    fi
    (
      cd "$publication_root"
      GIT_DIR=/nonexistent "$checker_path" >/dev/null
    )
  fi
  echo "$label historical evidence verified at publication $publication_oid"
done <"$registry_file"
