#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
manifest="$repo_root/docs/release/effect-linearity/MANIFEST.sha256"

if [ ! -f "$manifest" ]; then
  echo "missing effect-linearity evidence manifest: $manifest" >&2
  exit 1
fi

cd "$repo_root"
sha256sum --check --strict "$manifest"
