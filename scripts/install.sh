#!/usr/bin/env sh
set -eu

REPO=${JACQUARD_INSTALL_REPO:-jbwinters/jacquard-lang}
VERSION=${JACQUARD_INSTALL_VERSION:-jacquard-core-0.1-rc3}
PREFIX=${JACQUARD_INSTALL_PREFIX:-$HOME/.local}

# The installer also runs without a checkout, so its fallback is the user's
# cache rather than a repository-local .scratch directory.
: "${TMPDIR:=${XDG_CACHE_HOME:-$HOME/.cache}/jacquard/tmp}"
export TMPDIR
mkdir -p "$TMPDIR"

detect_target() {
  os=$(uname -s)
  arch=$(uname -m)
  case "$os:$arch" in
    Linux:x86_64 | Linux:amd64) echo "linux-x86_64" ;;
    Darwin:arm64) echo "macos-arm64" ;;
    Darwin:x86_64) echo "macos-x86_64" ;;
    *)
      echo "unsupported platform: $os $arch" >&2
      exit 1
      ;;
  esac
}

download() {
  url=$1
  out=$2
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$out"
  elif command -v wget >/dev/null 2>&1; then
    wget -q "$url" -O "$out"
  else
    echo "install requires curl or wget" >&2
    exit 1
  fi
}

TARGET=${JACQUARD_INSTALL_TARGET:-$(detect_target)}
ASSET="jacquard-$TARGET.tar.gz"

if [ -n "${JACQUARD_INSTALL_URL:-}" ]; then
  URL=$JACQUARD_INSTALL_URL
elif [ "$VERSION" = "latest" ]; then
  URL="https://github.com/$REPO/releases/latest/download/$ASSET"
else
  URL="https://github.com/$REPO/releases/download/$VERSION/$ASSET"
fi
CHECKSUM_URL="$URL.sha256"

tmp=$(mktemp -d "$TMPDIR/jacquard-install.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

echo "Downloading $URL"
download "$URL" "$tmp/$ASSET"
echo "Downloading $CHECKSUM_URL"
download "$CHECKSUM_URL" "$tmp/$ASSET.sha256"

if command -v sha256sum >/dev/null 2>&1; then
  (cd "$tmp" && sha256sum -c "$ASSET.sha256")
elif command -v shasum >/dev/null 2>&1; then
  (cd "$tmp" && shasum -a 256 -c "$ASSET.sha256")
else
  echo "install requires sha256sum or shasum to verify the release archive" >&2
  exit 1
fi

tar -xzf "$tmp/$ASSET" -C "$tmp"
root=$(find "$tmp" -mindepth 1 -maxdepth 1 -type d -name 'jacquard-*' | head -1)
if [ -z "$root" ]; then
  echo "archive did not contain a jacquard package root" >&2
  exit 1
fi

mkdir -p "$PREFIX/bin" "$PREFIX/libexec" "$PREFIX/share"
rm -rf "$PREFIX/libexec/jacquard" "$PREFIX/share/jacquard"
cp -R "$root/libexec/jacquard" "$PREFIX/libexec/jacquard"
cp -R "$root/share/jacquard" "$PREFIX/share/jacquard"
cp "$root/bin/jacquard" "$PREFIX/bin/jacquard"
chmod 0755 "$PREFIX/bin/jacquard"
ln -sfn jacquard "$PREFIX/bin/jac"

echo "Installed Jacquard to $PREFIX"
echo "Make sure $PREFIX/bin is on PATH, then run:"
echo "  jacquard --version"
echo "  jac --version"
