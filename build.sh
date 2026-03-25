#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load shared utilities
source "$SCRIPT_DIR/lib/common.sh"

# ---------------------------------------------------------------------------
# Initialization
# ---------------------------------------------------------------------------

read_version_pin
detect_sudo_user
setup_nvm_path
print_system_info

# ---------------------------------------------------------------------------
# Package format detection (auto-detect or override with FORMAT=rpm|deb|arch)
# ---------------------------------------------------------------------------

FORMAT="${FORMAT:-auto}"
if [ "$FORMAT" = "auto" ]; then
    FORMAT=$(detect_format)
    if [ -z "$FORMAT" ]; then
        echo "❌ Cannot detect package format. Set FORMAT=rpm, FORMAT=deb, or FORMAT=arch"
        exit 1
    fi
fi

echo "📦 Package format: $FORMAT"

if [ "$FORMAT" != "rpm" ] && [ "$FORMAT" != "deb" ] && [ "$FORMAT" != "arch" ]; then
    echo "❌ Unsupported format: $FORMAT (expected: rpm, deb, arch)"
    exit 1
fi

# ---------------------------------------------------------------------------
# Install dependencies (distro-specific)
# ---------------------------------------------------------------------------

source "$SCRIPT_DIR/lib/deps-${FORMAT}.sh"
install_deps

# ---------------------------------------------------------------------------
# Set lib directory based on format (RPM uses /usr/lib64, DEB/Arch use /usr/lib)
# ---------------------------------------------------------------------------

source "$SCRIPT_DIR/lib/package-${FORMAT}.sh"
set_lib_dir  # exports INSTALL_LIB_DIR

# ---------------------------------------------------------------------------
# Create working directories
# ---------------------------------------------------------------------------

WORK_DIR="$(pwd)/build"
PKG_ROOT="$WORK_DIR/package"
INSTALL_DIR="$PKG_ROOT/usr"

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR" "$PKG_ROOT"
mkdir -p "$INSTALL_DIR/lib/$PACKAGE_NAME"
mkdir -p "$INSTALL_DIR/share/applications"
mkdir -p "$INSTALL_DIR/share/icons"
mkdir -p "$INSTALL_DIR/bin"

# ---------------------------------------------------------------------------
# Download and extract
# ---------------------------------------------------------------------------

source "$SCRIPT_DIR/lib/download.sh"
download_and_extract

# ---------------------------------------------------------------------------
# Prepare (distro-agnostic: icons, stubs, patching, CLI, desktop entry)
# ---------------------------------------------------------------------------

source "$SCRIPT_DIR/lib/prepare.sh"
prepare_app

# ---------------------------------------------------------------------------
# Build package (distro-specific)
# ---------------------------------------------------------------------------

build_package
