#!/bin/sh
set -eu

# CI attests an immutable commit object, not the mutable runner worktree. The
# candidate must retain the exact published EL and SC manifest/checker bytes;
# their legacy checkers are then executed inside their pinned publication
# trees. --candidate-root is a test-only seam for disposable mutation copies.

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
  commit=$1
  git rev-parse --verify "$commit^{commit}" 2>/dev/null
}

archive_commit() {
  commit=$1
  destination=$2
  archive=$3
  mkdir -p "$destination"
  git archive --format=tar --output="$archive" "$commit"
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

check_retained_file() {
  label=$1
  expected=$2
  relative_path=$3
  file="$candidate_root/$relative_path"
  if [ ! -f "$file" ] || [ -L "$file" ]; then
    echo "$label retained file is missing or not regular: $relative_path" >&2
    exit 1
  fi
  actual=$(sha256sum "$file" | awk '{print $1}')
  if [ "$actual" != "$expected" ]; then
    echo "$label retained file drifted: $relative_path" >&2
    echo "expected $expected" >&2
    echo "actual   $actual" >&2
    exit 1
  fi
}

check_publication() {
  label=$1
  publication=$2
  manifest_path=$3
  manifest_sha=$4
  checker_path=$5
  checker_sha=$6

  publication_oid=$(resolve_commit "$publication") || {
    echo "$label publication commit is unavailable: $publication" >&2
    exit 1
  }
  if [ -n "$candidate_commit" ] &&
    ! git merge-base --is-ancestor "$publication_oid" "$candidate_oid"; then
    echo "$label publication $publication_oid is not an ancestor of candidate $candidate_oid" >&2
    exit 1
  fi

  check_retained_file "$label" "$manifest_sha" "$manifest_path"
  check_retained_file "$label" "$checker_sha" "$checker_path"

  publication_root="$temp_root/publication-$label"
  archive_commit \
    "$publication_oid" "$publication_root" "$temp_root/publication-$label.tar"

  publication_manifest_sha=$(sha256sum "$publication_root/$manifest_path" | awk '{print $1}')
  publication_checker_sha=$(sha256sum "$publication_root/$checker_path" | awk '{print $1}')
  if [ "$publication_manifest_sha" != "$manifest_sha" ] ||
    [ "$publication_checker_sha" != "$checker_sha" ]; then
    echo "$label publication anchors do not match the pinned byte identities" >&2
    exit 1
  fi

  (
    cd "$publication_root"
    GIT_DIR=/nonexistent "$checker_path" >/dev/null
  )
  echo "$label historical evidence verified at publication $publication_oid"
}

check_publication \
  EL \
  9f04e972cb990257a85331943f486c1623cb57b5 \
  docs/release/effect-linearity/MANIFEST.sha256 \
  c4b7fe35abefd2e77de124a57fe5baa8d7e844969eb778955f1c520161241d0b \
  scripts/release/check-effect-linearity-manifest.sh \
  c1c4fd476119732fae529b1100d5307f061d0a275bd28b3f3551bcf2b89cfdb2

check_publication \
  SC \
  81c14506e0d099dabe04a40b00c1d4fc45b42d47 \
  docs/release/structured-concurrency/MANIFEST.sha256 \
  3ca69edb0121713deb211042dfe2099bbd425c05292789d46a5db00e4d52ffd9 \
  scripts/release/check-structured-concurrency-manifest.sh \
  d0b40d94343a06343f08dbcf2a11c7b11fcf8a465df4e3375b4bfd703b62a495

check_publication \
  SC17 \
  7cd3054652674eeaae4bfae8483c909819589f66 \
  docs/release/structured-concurrency/SC17-MANIFEST.sha256 \
  dd597d01e8d806fa8d962db419ca23ecb16031989526dd3ee01b130567eb6c50 \
  scripts/release/check-sc17-manifest.sh \
  4e35e42c06b251d9caefb34970f7d66cd5aca58c4f4caaa342efb20045e036ae
