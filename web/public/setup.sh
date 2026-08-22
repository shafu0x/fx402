#!/bin/sh
set -eu

REPO="shafu0x/fx402"
INSTALL_DIR="${FX402_INSTALL_DIR:-$HOME/.fx402/bin}"
API="https://api.github.com/repos/${REPO}/releases"

os=$(uname -s)
arch=$(uname -m)

case "$os" in
  Darwin) platform_os="macos" ;;
  Linux) platform_os="linux" ;;
  *)
    echo "fx402: unsupported OS: $os (need macOS or Linux)" >&2
    exit 1
    ;;
esac

case "$arch" in
  x86_64 | amd64) platform_arch="x86_64" ;;
  arm64 | aarch64) platform_arch="aarch64" ;;
  *)
    echo "fx402: unsupported architecture: $arch (need x86_64 or arm64)" >&2
    exit 1
    ;;
esac

platform="${platform_os}-${platform_arch}"

if [ -n "${FX402_VERSION:-}" ]; then
  version="$FX402_VERSION"
else
  version=$(curl -fsSL "${API}/latest" | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
fi

if [ -z "$version" ]; then
  echo "fx402: could not resolve the latest release. Set FX402_VERSION=v0.1.0 and retry." >&2
  exit 1
fi

case "$version" in
  v*) ;;
  *) version="v${version}" ;;
esac

asset="fx402-${platform}.tar.gz"
base="https://github.com/${REPO}/releases/download/${version}"
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

echo "fx402: installing ${version} for ${platform}"

curl -fsSL "${base}/${asset}" -o "${tmpdir}/${asset}"
curl -fsSL "${base}/${asset}.sha256" -o "${tmpdir}/${asset}.sha256"

(
  cd "$tmpdir"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -c "${asset}.sha256"
  else
    shasum -a 256 -c "${asset}.sha256"
  fi
)

mkdir -p "$INSTALL_DIR"
tar -xzf "${tmpdir}/${asset}" -C "$tmpdir"
cp "${tmpdir}/fx402" "${INSTALL_DIR}/fx402"
chmod 755 "${INSTALL_DIR}/fx402"

echo "fx402: installed ${INSTALL_DIR}/fx402"
echo
echo "Add this to your shell rc if it is not already on PATH:"
echo "  export PATH=\"${INSTALL_DIR}:\$PATH\""
echo
echo "The wallet is created at ~/.fx/wallet.json on first run."
echo "Ask fx402 for the address when a payment needs funds."
