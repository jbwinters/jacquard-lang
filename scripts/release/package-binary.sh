#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT"

detect_target() {
  os=$(uname -s)
  arch=$(uname -m)
  case "$os:$arch" in
    Linux:x86_64 | Linux:amd64) echo "linux-x86_64" ;;
    Darwin:arm64) echo "macos-arm64" ;;
    Darwin:x86_64) echo "macos-x86_64" ;;
    *) echo "unsupported-$os-$arch" | tr '[:upper:]' '[:lower:]' ;;
  esac
}

TARGET=${1:-$(detect_target)}
VERSION=${JACQUARD_VERSION:-$(_build/default/bin/main.exe --version 2>/dev/null || echo dev)}
DIST=${JACQUARD_DIST_DIR:-dist}
ARCHIVE="jacquard-${TARGET}.tar.gz"

opam exec -- dune build @install
VERSION=$(_build/default/bin/main.exe --version)

BIN="_build/install/default/bin/jacquard"
if [ ! -x "$BIN" ]; then
  BIN="_build/default/bin/main.exe"
fi

mkdir -p "$DIST"
rm -f "$DIST/$ARCHIVE" "$DIST/$ARCHIVE.sha256"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/jacquard-package.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

pkg="$tmp/jacquard-$VERSION-$TARGET"
mkdir -p "$pkg/bin" "$pkg/libexec/jacquard" "$pkg/share/jacquard"

cp "$BIN" "$pkg/libexec/jacquard/jacquard"
cp -R prelude "$pkg/share/jacquard/prelude"
cp -R demos "$pkg/share/jacquard/demos"
cp LICENSE "$pkg/LICENSE"
cp TRADEMARKS.md "$pkg/TRADEMARKS.md"
cp COMMERCIAL-LICENSE.md "$pkg/COMMERCIAL-LICENSE.md"

cat >"$pkg/bin/jacquard" <<'SH'
#!/usr/bin/env sh
set -eu

prefix=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
: "${JACQUARD_PRELUDE:=$prefix/share/jacquard/prelude}"
export JACQUARD_PRELUDE

exec "$prefix/libexec/jacquard/jacquard" "$@"
SH
chmod 0755 "$pkg/bin/jacquard"
ln -s jacquard "$pkg/bin/jac"

cat >"$pkg/README.md" <<EOF
# Jacquard $VERSION

This archive contains the Jacquard CLI and standard prelude.

## Contents

- \`bin/jacquard\`: wrapper that sets \`JACQUARD_PRELUDE\`
- \`bin/jac\`: short alias for \`jacquard\`
- \`libexec/jacquard/jacquard\`: native executable
- \`share/jacquard/prelude\`: standard library
- \`share/jacquard/demos\`: runnable examples
- \`LICENSE\`: AGPL-3.0-or-later public license
- \`TRADEMARKS.md\`: Jacquard name and mark policy
- \`COMMERCIAL-LICENSE.md\`: commercial licensing path

## Manual Install

\`\`\`sh
cp -R bin libexec share "\$HOME/.local/"
jacquard --version
jac --version
jac run "\$HOME/.local/share/jacquard/demos/m1-fact.jac"
\`\`\`
EOF

(cd "$tmp" && tar -czf "$ROOT/$DIST/$ARCHIVE" "jacquard-$VERSION-$TARGET")
(cd "$DIST" && shasum -a 256 "$ARCHIVE" >"$ARCHIVE.sha256")

printf '%s\n' "$DIST/$ARCHIVE"
printf '%s\n' "$DIST/$ARCHIVE.sha256"
