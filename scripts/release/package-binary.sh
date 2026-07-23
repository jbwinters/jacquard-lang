#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT"
: "${TMPDIR:=$ROOT/.scratch/tmp}"
export TMPDIR
mkdir -p "$TMPDIR"

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
case "$DIST" in
  /*) DIST_DIR=$DIST ;;
  *) DIST_DIR=$ROOT/$DIST ;;
esac

opam exec -- dune build --root "$ROOT" @install
VERSION=$(_build/default/bin/main.exe --version)

BIN="_build/install/default/bin/jacquard"
if [ ! -x "$BIN" ]; then
  BIN="_build/default/bin/main.exe"
fi

mkdir -p "$DIST_DIR"
rm -f "$DIST_DIR/$ARCHIVE" "$DIST_DIR/$ARCHIVE.sha256"

tmp=$(mktemp -d "$TMPDIR/jacquard-package.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

pkg="$tmp/jacquard-$VERSION-$TARGET"
mkdir -p "$pkg/bin" "$pkg/libexec/jacquard" "$pkg/share/jacquard/runtime"

cp "$BIN" "$pkg/libexec/jacquard/jacquard"
cp -R prelude "$pkg/share/jacquard/prelude"
cp -R demos "$pkg/share/jacquard/demos"
cp runtime/jq_*.c runtime/jq_value.h "$pkg/share/jacquard/runtime/"
cp LICENSE "$pkg/share/jacquard/LICENSE"
cp NOTICE "$pkg/share/jacquard/NOTICE"
cp RUNTIME-EXCEPTION.md "$pkg/share/jacquard/RUNTIME-EXCEPTION.md"
cp TRADEMARKS.md "$pkg/share/jacquard/TRADEMARKS.md"
cp LICENSE "$pkg/LICENSE"
cp NOTICE "$pkg/NOTICE"
cp RUNTIME-EXCEPTION.md "$pkg/RUNTIME-EXCEPTION.md"
cp TRADEMARKS.md "$pkg/TRADEMARKS.md"

cat >"$pkg/bin/jacquard" <<'SH'
#!/usr/bin/env sh
set -eu

prefix=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
: "${JACQUARD_PRELUDE:=$prefix/share/jacquard/prelude}"
: "${JACQUARD_RUNTIME:=$prefix/share/jacquard/runtime}"
export JACQUARD_PRELUDE
export JACQUARD_RUNTIME

exec "$prefix/libexec/jacquard/jacquard" "$@"
SH
chmod 0755 "$pkg/bin/jacquard"
ln -s jacquard "$pkg/bin/jac"

cat >"$pkg/README.md" <<EOF
# Jacquard $VERSION

This archive contains the Jacquard CLI, standard prelude, demos, and native C
runtime.

## Contents

- \`bin/jacquard\`: wrapper that sets \`JACQUARD_PRELUDE\` and \`JACQUARD_RUNTIME\`
- \`bin/jac\`: short alias for \`jacquard\`
- \`libexec/jacquard/jacquard\`: native executable
- \`share/jacquard/prelude\`: standard library
- \`share/jacquard/demos\`: runnable examples
- \`share/jacquard/runtime\`: C runtime used by \`jac build\`
- \`share/jacquard/LICENSE\`, \`share/jacquard/NOTICE\`, and \`share/jacquard/RUNTIME-EXCEPTION.md\`: installed license terms
- \`LICENSE\`: Apache License, Version 2.0
- \`NOTICE\`: Jacquard attribution notice
- \`RUNTIME-EXCEPTION.md\`: permission to license user programs and compiled output under terms of their authors' choice
- \`TRADEMARKS.md\`: Jacquard name and mark policy

## Manual Install

\`\`\`sh
cp -R bin libexec share "\$HOME/.local/"
jacquard --version
jac --version
jac run "\$HOME/.local/share/jacquard/demos/basics/m1-fact.jac"
sh "\$HOME/.local/share/jacquard/demos/worlds/escrow/run.sh"
\`\`\`

Programs written in Jacquard and native executables produced by \`jac build\`
may use any license chosen by their authors. Jacquard itself is Apache-2.0,
and the runtime/output permission prevents embedded runtime material from
imposing notice obligations on user programs.
EOF

(cd "$tmp" && tar -czf "$DIST_DIR/$ARCHIVE" "jacquard-$VERSION-$TARGET")
(cd "$DIST_DIR" && shasum -a 256 "$ARCHIVE" >"$ARCHIVE.sha256")

printf '%s\n' "$DIST_DIR/$ARCHIVE"
printf '%s\n' "$DIST_DIR/$ARCHIVE.sha256"
