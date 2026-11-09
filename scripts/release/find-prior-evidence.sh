#!/bin/sh
# Find an earlier successful Release Evidence run that reproduced exactly this
# commit against this candidate base, so a tag push can reuse it instead of
# repeating the multi-hour reproduction (docs/ci-cd.md, Release Evidence).
#
# A run that reproduces the evidence uploads a marker artifact named
# release-evidence-pass-<commit>-<base> after the reproduction succeeds. This
# script accepts a marker only when the run that produced it
#   - is the Release Evidence workflow (.github/workflows/release-evidence.yml),
#   - was started in this repository by a push to a release/* branch whose
#     pushed commit is <commit> itself, so the run executed the tagged commit's
#     own workflow and scripts on the tagged commit; a pull request, another
#     branch, and any manual dispatch are refused, because a dispatch runs the
#     code of its ref input, which the run record does not show,
#   - completed with conclusion success,
# and the marker has not expired.
#
# usage: find-prior-evidence.sh <repo> <commit> <base>
# Prints the accepted run's id and exits 0, or prints nothing and exits 1. Any
# API or parse failure also exits 1, so the caller falls back to a full
# reproduction (fail closed). GH names the gh executable (default gh).
set -eu

if [ "$#" -ne 3 ]; then
  echo "usage: find-prior-evidence.sh <repo> <commit> <base>" >&2
  exit 2
fi
repo=$1
commit=$2
base=$3
gh=${GH:-gh}
workflow_path=.github/workflows/release-evidence.yml

case "$commit$base" in
  *[!0-9a-f]*)
    echo "commit and base must be full lowercase hex object names" >&2
    exit 2
    ;;
esac
if [ "${#commit}" -ne 40 ] || [ "${#base}" -ne 40 ]; then
  echo "commit and base must be full lowercase hex object names" >&2
  exit 2
fi

marker="release-evidence-pass-$commit-$base"
artifacts=$("$gh" api --paginate "repos/$repo/actions/artifacts?name=$marker&per_page=100") || exit 1
run_ids=$(printf '%s\n' "$artifacts" |
  jq -r '.artifacts[] | select(.expired == false) | .workflow_run.id' 2>/dev/null) || exit 1

# Split the ids on whitespace only; never expand them as file name patterns.
set -f
for run_id in $run_ids; do
  case "$run_id" in
    '' | *[!0-9]*) continue ;;
  esac
  run=$("$gh" api "repos/$repo/actions/runs/$run_id") || continue
  accepted=$(printf '%s\n' "$run" |
    jq -r --arg path "$workflow_path" --arg repo "$repo" --arg commit "$commit" '
      (.path | split("@")[0]) == $path
      and .event == "push"
      and (.head_branch | startswith("release/"))
      and .head_sha == $commit
      and .conclusion == "success"
      and .head_repository.full_name == $repo' 2>/dev/null) || continue
  if [ "$accepted" = true ]; then
    echo "$run_id"
    exit 0
  fi
done
exit 1
