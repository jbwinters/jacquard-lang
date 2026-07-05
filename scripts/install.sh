#!/usr/bin/env sh
set -eu

REPO=${JACQUARD_INSTALL_REPO:-jbwinters/jacquard-lang}
VERSION=${JACQUARD_INSTALL_VERSION:-latest}
PREFIX=${JACQUARD_INSTALL_PREFIX:-$HOME/.local}

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

if [ "$VERSION" = "latest" ]; then
  URL="https://github.com/$REPO/releases/latest/download/$ASSET"
else
  URL="https://github.com/$REPO/releases/download/$VERSION/$ASSET"
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/jacquard-install.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

echo "Downloading $URL"
download "$URL" "$tmp/$ASSET"

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
