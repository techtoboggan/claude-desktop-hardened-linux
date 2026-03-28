#!/bin/bash
# Smoke test: verify built packages contain expected files and structure.
# Usage: bash tests/test_package_contents.sh <format> <package-path>
#   format: rpm | deb | arch
#   package-path: path to the built .rpm, .deb, or .pkg.tar.zst
set -uo pipefail

FORMAT="${1:-}"
PKG="${2:-}"
PASS=0
FAIL=0

check() {
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        echo "  PASS: $desc"
        ((PASS++))
    else
        echo "  FAIL: $desc"
        ((FAIL++))
    fi
}

if [ -z "$FORMAT" ] || [ -z "$PKG" ]; then
    echo "Usage: $0 <rpm|deb|arch> <package-file>"
    exit 1
fi

if [ ! -f "$PKG" ]; then
    echo "Package file not found: $PKG"
    exit 1
fi

# -------------------------------------------------------------------------
# Extract file listing from the package
# -------------------------------------------------------------------------

case "$FORMAT" in
    rpm)
        LISTING=$(rpm -qlp "$PKG" 2>/dev/null)
        LIB_PREFIX="/usr/lib64/claude-desktop-hardened"
        ;;
    deb)
        LISTING=$(dpkg-deb -c "$PKG" 2>/dev/null | awk '{print $NF}' | sed 's|^\./|/|')
        LIB_PREFIX="/usr/lib/claude-desktop-hardened"
        ;;
    arch)
        LISTING=$(tar -tf "$PKG" 2>/dev/null | sed 's|^|/|; s|//$|/|')
        LIB_PREFIX="/usr/lib/claude-desktop-hardened"
        ;;
    *)
        echo "Unknown format: $FORMAT"
        exit 1
        ;;
esac

if [ -z "$LISTING" ]; then
    echo "FAIL: Could not read package contents"
    exit 1
fi

has_file() {
    echo "$LISTING" | grep -qF "$1"
}

has_pattern() {
    echo "$LISTING" | grep -qE "$1"
}

echo "=== Package Content Tests ($FORMAT) ==="
echo "  Package: $PKG"
echo

# -------------------------------------------------------------------------
# Binaries
# -------------------------------------------------------------------------
echo "--- Binaries ---"
check "launcher exists" has_file "/usr/bin/claude-desktop-hardened"
check "CLI wrapper exists" has_file "/usr/bin/claude"

# -------------------------------------------------------------------------
# Core app files
# -------------------------------------------------------------------------
echo "--- Core App ---"
check "app.asar exists" has_file "${LIB_PREFIX}/app.asar"
check "app.asar.unpacked exists" has_pattern "${LIB_PREFIX}/app.asar.unpacked/"

# -------------------------------------------------------------------------
# Stubs (cowork, claude-native)
# -------------------------------------------------------------------------
echo "--- Stubs ---"
check "cowork stub exists" has_pattern "${LIB_PREFIX}/app.asar.unpacked/node_modules/cowork/"
check "claude-native stub exists" has_pattern "${LIB_PREFIX}/app.asar.unpacked/node_modules/.*(claude-native|@ant/claude-native)/"

# -------------------------------------------------------------------------
# Claude Code CLI
# -------------------------------------------------------------------------
echo "--- Claude Code CLI ---"
check "claude-code directory exists" has_pattern "${LIB_PREFIX}/claude-code/"
check "claude-code node_modules exists" has_pattern "${LIB_PREFIX}/claude-code/node_modules/"

# -------------------------------------------------------------------------
# Desktop integration
# -------------------------------------------------------------------------
echo "--- Desktop Integration ---"
check "desktop entry exists" has_file "/usr/share/applications/claude-desktop-hardened.desktop"

# Icons (at least some of the standard sizes)
check "256px icon exists" has_pattern "/usr/share/icons/hicolor/256x256/apps/claude-desktop-hardened.png"
check "48px icon exists" has_pattern "/usr/share/icons/hicolor/48x48/apps/claude-desktop-hardened.png"
check "32px icon exists" has_pattern "/usr/share/icons/hicolor/32x32/apps/claude-desktop-hardened.png"

# -------------------------------------------------------------------------
# Doctor diagnostic
# -------------------------------------------------------------------------
echo "--- Diagnostics ---"
check "doctor.sh exists" has_file "/usr/share/claude-desktop-hardened/doctor.sh"

# -------------------------------------------------------------------------
# DEB-specific: maintainer scripts
# -------------------------------------------------------------------------
if [ "$FORMAT" = "deb" ]; then
    echo "--- DEB Maintainer Scripts ---"
    CONTROL=$(dpkg-deb --info "$PKG" 2>/dev/null)
    check "has postinst" grep -q "postinst" <<< "$CONTROL"
    check "has postrm" grep -q "postrm" <<< "$CONTROL"
fi

# -------------------------------------------------------------------------
# Desktop entry validation (extract and check)
# -------------------------------------------------------------------------
echo "--- Desktop Entry Validation ---"
DESKTOP_CONTENT=""
case "$FORMAT" in
    rpm)
        DESKTOP_CONTENT=$(rpm2cpio "$PKG" 2>/dev/null | cpio -i --to-stdout "*claude-desktop-hardened.desktop" 2>/dev/null)
        ;;
    deb)
        TMPDIR=$(mktemp -d)
        dpkg-deb -x "$PKG" "$TMPDIR" 2>/dev/null
        DESKTOP_CONTENT=$(cat "$TMPDIR/usr/share/applications/claude-desktop-hardened.desktop" 2>/dev/null)
        rm -rf "$TMPDIR"
        ;;
    arch)
        DESKTOP_CONTENT=$(tar -xf "$PKG" -O "usr/share/applications/claude-desktop-hardened.desktop" 2>/dev/null)
        ;;
esac

if [ -n "$DESKTOP_CONTENT" ]; then
    check "desktop entry has Name" grep -q "^Name=" <<< "$DESKTOP_CONTENT"
    check "desktop entry has Exec" grep -q "^Exec=claude-desktop-hardened" <<< "$DESKTOP_CONTENT"
    check "desktop entry has Icon" grep -q "^Icon=claude-desktop-hardened" <<< "$DESKTOP_CONTENT"
    check "desktop entry has StartupWMClass" grep -q "^StartupWMClass=" <<< "$DESKTOP_CONTENT"
else
    echo "  SKIP: Could not extract desktop entry for validation"
fi

# -------------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------------
echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
