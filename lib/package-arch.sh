#!/bin/bash
# Arch Linux packaging via makepkg.

set_lib_dir() {
    export INSTALL_LIB_DIR="/usr/lib/claude-desktop-hardened"
}

build_package() {
    log_step "📦" "Building Arch package..."

    # Set up makepkg staging
    local ARCH_ROOT="$WORK_DIR/arch-staging"
    rm -rf "$ARCH_ROOT"
    mkdir -p "$ARCH_ROOT/src/staged/usr/lib/claude-desktop-hardened"
    mkdir -p "$ARCH_ROOT/src/staged/usr/bin"
    mkdir -p "$ARCH_ROOT/src/staged/usr/share"

    # Copy staged files
    cp -r "$INSTALL_DIR/lib/$PACKAGE_NAME/"* "$ARCH_ROOT/src/staged/usr/lib/claude-desktop-hardened/"
    cp -r "$INSTALL_DIR/bin/"* "$ARCH_ROOT/src/staged/usr/bin/"
    cp -r "$INSTALL_DIR/share/applications" "$ARCH_ROOT/src/staged/usr/share/"
    cp -r "$INSTALL_DIR/share/icons" "$ARCH_ROOT/src/staged/usr/share/"
    if [ -d "$INSTALL_DIR/share/$PACKAGE_NAME" ]; then
        cp -r "$INSTALL_DIR/share/$PACKAGE_NAME" "$ARCH_ROOT/src/staged/usr/share/"
    fi

    # Generate PKGBUILD from template
    sed -e "s|@@VERSION@@|${VERSION}|g" \
        -e "s|@@SHA256@@|${CLAUDE_NUPKG_SHA256:-SKIP}|g" \
        "$SCRIPT_DIR/packaging/arch/PKGBUILD.in" > "$ARCH_ROOT/PKGBUILD"

    # Build the package (makepkg refuses to run as root, so use a temp user in CI)
    cd "$ARCH_ROOT"
    local MAKEPKG_CMD="makepkg -f --nodeps"
    if [ "$EUID" -eq 0 ]; then
        # Running as root (CI container) — create a temp user for makepkg
        useradd -m -s /bin/bash _builduser 2>/dev/null || true
        chown -R _builduser:_builduser "$ARCH_ROOT"
        MAKEPKG_CMD="su _builduser -s /bin/bash -c 'makepkg -f --nodeps'"
    fi
    if eval "$MAKEPKG_CMD"; then
        local PKG_FILE
        PKG_FILE=$(ls claude-desktop-hardened-*.pkg.tar.* 2>/dev/null | head -1)
        if [ -n "$PKG_FILE" ]; then
            # Move to output location
            mkdir -p "$WORK_DIR/electron-app/$ARCHITECTURE"
            mv "$PKG_FILE" "$WORK_DIR/electron-app/$ARCHITECTURE/"
            log_ok "Arch package built successfully at: $WORK_DIR/electron-app/$ARCHITECTURE/$PKG_FILE"
            echo "🎉 Done! Install with: sudo pacman -U $WORK_DIR/electron-app/$ARCHITECTURE/$PKG_FILE"
        fi
    else
        # If makepkg fails (e.g., not on Arch), just produce the PKGBUILD
        mkdir -p "$WORK_DIR/electron-app/$ARCHITECTURE"
        cp "$ARCH_ROOT/PKGBUILD" "$WORK_DIR/electron-app/$ARCHITECTURE/PKGBUILD"
        log_warn "makepkg not available or failed. PKGBUILD generated at: $WORK_DIR/electron-app/$ARCHITECTURE/PKGBUILD"
    fi
}
