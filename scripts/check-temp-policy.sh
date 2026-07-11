#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

# Keep the forbidden path split so this guard does not match its own source.
root_tmp="/""tmp"
path_token="(^|[=:[:space:]\"'{}-])${root_tmp}(/|[[:space:]\"'{}]|$)"
if git grep -n -E "$path_token" -- ':(glob).github/workflows/*.yml' \
  ':(glob)scripts/**/*.sh' ':(glob)runtime/*.sh' ':(glob)demos/*.sh' \
  ':(glob)demos/**/*.sh'
then
  echo "Jacquard automation must keep temporary artifacts out of the root temp directory" >&2
  exit 1
fi

echo "temporary storage policy: PASS"
