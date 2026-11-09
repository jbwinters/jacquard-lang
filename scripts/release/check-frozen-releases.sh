#!/bin/sh
# Published release documents are frozen at their release tags: each
# docs/release/<version>/ directory below must be byte-identical, file for
# file, to its tag. Each tag is pinned to its published commit, so a moved tag
# cannot move the baseline. Work after a release is recorded in
# docs/release/unreleased/.
#
# usage: check-frozen-releases.sh --commit <commit>
# Exits 0 when every frozen directory matches its tag, 1 when one differs or a
# tag or the commit is unavailable, 2 on a usage error.
set -eu

if [ "$#" -ne 2 ] || [ "$1" != --commit ]; then
  echo "usage: check-frozen-releases.sh --commit <commit>" >&2
  exit 2
fi

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$repo_root"
commit=$(git rev-parse --verify "$2^{commit}" 2>/dev/null) || {
  echo "commit is unavailable: $2" >&2
  exit 1
}

status=0
for entry in \
  jacquard-core-0.2.0:aceca65e364db6dcf91cbdd54586c136646dfa37:docs/release/0.2 \
  jacquard-core-0.3.0:daf87fb4837cc69339116746818f64821dc4cb8e:docs/release/0.3; do
  tag=${entry%%:*}
  rest=${entry#*:}
  pinned=${rest%%:*}
  dir=${rest#*:}
  if ! tagged=$(git rev-parse --verify --quiet "refs/tags/$tag^{commit}"); then
    echo "release tag is unavailable: $tag" >&2
    status=1
    continue
  fi
  if [ "$tagged" != "$pinned" ]; then
    echo "release tag $tag names $tagged, not its published commit $pinned" >&2
    status=1
    continue
  fi
  if git diff --quiet "$pinned" "$commit" -- "$dir"; then
    echo "$dir matches $tag"
  else
    echo "$dir differs from $tag; released documents are frozen:" >&2
    git diff --stat "$pinned" "$commit" -- "$dir" >&2
    status=1
  fi
done
exit "$status"
