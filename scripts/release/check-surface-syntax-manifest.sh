#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
manifest="$repo_root/docs/release/surface-syntax/MANIFEST.sha256"
boundary="52f36133b95349ae481f091e0043e71bc1452bc3"
manifest_sha="c8c245de2c999c805a3902089d9f2c23f698931a451b93e354514811cc069515"

if [ ! -f "$manifest" ]; then
  echo "missing surface-syntax evidence manifest: $manifest" >&2
  exit 1
fi

actual_manifest_sha=$(sha256sum "$manifest" | awk '{print $1}')
if [ "$actual_manifest_sha" != "$manifest_sha" ]; then
  echo "surface-syntax evidence manifest changed: expected $manifest_sha, got $actual_manifest_sha" >&2
  exit 1
fi

cd "$repo_root"
if ! git cat-file -e "$boundary^{commit}" 2>/dev/null; then
  echo "surface-syntax manifest bytes match the immutable SS.22 attestation; historical Git object unavailable"
  exit 0
fi

while read -r expected file_path; do
  case "$expected" in
    ''|'#'*) continue ;;
  esac
  actual=$(git show "$boundary:$file_path" | sha256sum | awk '{print $1}')
  if [ "$actual" != "$expected" ]; then
    echo "$file_path: SS.22 boundary hash mismatch: expected $expected, got $actual" >&2
    exit 1
  fi
done < "$manifest"

echo "surface-syntax manifest matches immutable SS.22 boundary $boundary"
