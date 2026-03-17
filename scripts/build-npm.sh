#!/usr/bin/env bash
#
# Build the npm distribution packages locally (current platform only).
# Usage: ./scripts/build-npm.sh [version]
#
# This builds the CLI binary and packages it for local testing.
# For cross-platform builds, use the GitHub Actions workflow.
#
set -euo pipefail

VERSION="${1:-0.1.0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Detect current platform
PLATFORM="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"

case "$ARCH" in
  x86_64)  ARCH="x64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

NPM_PKG="openusage-${PLATFORM}-${ARCH}"
echo "Building for: ${PLATFORM}-${ARCH} -> ${NPM_PKG}"

# Build release binary
echo "Building CLI binary..."
cargo build -p openusage-cli --release

# Package the platform binary
echo "Packaging ${NPM_PKG}..."
mkdir -p "${ROOT_DIR}/npm/${NPM_PKG}/bin"
cp "${ROOT_DIR}/target/release/openusage" "${ROOT_DIR}/npm/${NPM_PKG}/bin/openusage"
chmod +x "${ROOT_DIR}/npm/${NPM_PKG}/bin/openusage"

# Bundle plugins into root package
echo "Bundling plugins..."
rm -rf "${ROOT_DIR}/npm/openusage/plugins"
mkdir -p "${ROOT_DIR}/npm/openusage/plugins"
for plugin_dir in "${ROOT_DIR}/plugins"/*/; do
  plugin_name="$(basename "$plugin_dir")"
  if [ "$plugin_name" = "mock" ]; then continue; fi
  cp -r "$plugin_dir" "${ROOT_DIR}/npm/openusage/plugins/$plugin_name"
done

# Set version in all package.json files
echo "Setting version to ${VERSION}..."
for pkg_dir in "${ROOT_DIR}"/npm/*/; do
  if [ -f "${pkg_dir}/package.json" ]; then
    cd "$pkg_dir"
    npm version "$VERSION" --no-git-tag-version --allow-same-version 2>/dev/null
    cd "$ROOT_DIR"
  fi
done

# Update optionalDependencies versions
cd "${ROOT_DIR}/npm/openusage"
node -e "
  const pkg = require('./package.json');
  for (const dep of Object.keys(pkg.optionalDependencies || {})) {
    pkg.optionalDependencies[dep] = '${VERSION}';
  }
  require('fs').writeFileSync('package.json', JSON.stringify(pkg, null, 2) + '\n');
"
cd "$ROOT_DIR"

echo ""
echo "Done! To test locally:"
echo "  cd npm/openusage && npm link"
echo "  openusage"
echo ""
echo "Or test directly:"
echo "  node npm/openusage/bin/openusage"
