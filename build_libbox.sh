#!/bin/bash
# build_libbox.sh – Build Libbox.xcframework for iOS from sing-box source
# Usage: ./build_libbox.sh [version]
# Example: ./build_libbox.sh 1.12.22

set -euo pipefail

SING_BOX_VERSION="${1:-1.12.22}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/.build_libbox"

echo "=== Building Libbox.xcframework for iOS (sing-box v${SING_BOX_VERSION}) ==="

# ── Prerequisites check ──
command -v go >/dev/null 2>&1 || { echo "ERROR: Go is required. Install: brew install go"; exit 1; }

GO_VERSION=$(go version | grep -oE 'go[0-9]+\.[0-9]+' | head -1)
echo "Go version: ${GO_VERSION}"

# ── Install gomobile ──
echo "Installing gomobile..."
go install github.com/sagernet/gomobile/cmd/gomobile@v0.1.8
go install github.com/sagernet/gomobile/cmd/gobind@v0.1.8
export PATH="$(go env GOPATH)/bin:$PATH"

# ── Clone/update sing-box source ──
if [ -d "${BUILD_DIR}/sing-box" ]; then
    echo "Updating sing-box source..."
    cd "${BUILD_DIR}/sing-box"
    git fetch --tags
else
    echo "Cloning sing-box source..."
    mkdir -p "${BUILD_DIR}"
    cd "${BUILD_DIR}"
    git clone --depth 1 --branch "v${SING_BOX_VERSION}" https://github.com/SagerNet/sing-box.git
    cd sing-box
fi

git checkout "v${SING_BOX_VERSION}" 2>/dev/null || git checkout "tags/v${SING_BOX_VERSION}"

# ── Build libbox for iOS ──
echo "Building Libbox.xcframework (iOS only)..."
go run ./cmd/internal/build_libbox -target apple -platform ios

# ── Copy output ──
FRAMEWORK_SRC="${BUILD_DIR}/sing-box/Libbox.xcframework"
if [ ! -d "${FRAMEWORK_SRC}" ]; then
    # Check alternative locations
    FRAMEWORK_SRC=$(find "${BUILD_DIR}/sing-box" -name "Libbox.xcframework" -type d | head -1)
fi

if [ -z "${FRAMEWORK_SRC}" ] || [ ! -d "${FRAMEWORK_SRC}" ]; then
    echo "ERROR: Libbox.xcframework not found after build."
    echo "Check the build output above for errors."
    echo "You may need to run manually:"
    echo "  cd ${BUILD_DIR}/sing-box"
    echo "  go run ./cmd/internal/build_libbox -target apple -platform ios"
    exit 1
fi

DEST="${SCRIPT_DIR}/Libbox.xcframework"
rm -rf "${DEST}"
cp -R "${FRAMEWORK_SRC}" "${DEST}"

echo ""
echo "=== SUCCESS ==="
echo "Libbox.xcframework built at: ${DEST}"
echo ""
echo "Next steps:"
echo "1. Open SimpleProxyClient.xcodeproj in Xcode"
echo "2. Drag Libbox.xcframework into the project"
echo "3. Add it to the PacketTunnel extension target"
echo "4. See SETUP.md for complete instructions"
