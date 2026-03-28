#!/bin/bash
# DEB packaging via dpkg-deb.

set_lib_dir() {
    export INSTALL_LIB_DIR="/usr/lib/claude-desktop-hardened"
}

build_package() {
    local DEB_ARCH
    DEB_ARCH=$(arch_to_deb)

    log_step "📦" "Building DEB package..."

    # Set up the DEB staging directory
    local DEB_ROOT="$WORK_DIR/deb-staging"
    rm -rf "$DEB_ROOT"
    mkdir -p "$DEB_ROOT/DEBIAN"
    mkdir -p "$DEB_ROOT/usr/lib/claude-desktop-hardened"
    mkdir -p "$DEB_ROOT/usr/bin"
    mkdir -p "$DEB_ROOT/usr/share/applications"
    mkdir -p "$DEB_ROOT/usr/share/icons"

    # Copy staged files (prepare.sh put them under $PKG_ROOT/usr/)
    cp -r "$INSTALL_DIR/lib/$PACKAGE_NAME/"* "$DEB_ROOT/usr/lib/claude-desktop-hardened/"
    cp -r "$INSTALL_DIR/bin/"* "$DEB_ROOT/usr/bin/"
    cp -r "$INSTALL_DIR/share/applications/"* "$DEB_ROOT/usr/share/applications/"
    cp -r "$INSTALL_DIR/share/icons/"* "$DEB_ROOT/usr/share/icons/"
    if [ -d "$INSTALL_DIR/share/$PACKAGE_NAME" ]; then
        mkdir -p "$DEB_ROOT/usr/share/$PACKAGE_NAME"
        cp -r "$INSTALL_DIR/share/$PACKAGE_NAME/"* "$DEB_ROOT/usr/share/$PACKAGE_NAME/"
    fi

    # Generate control file from template
    sed -e "s|@@VERSION@@|${VERSION}|g" \
        -e "s|@@DEB_ARCH@@|${DEB_ARCH}|g" \
        "$SCRIPT_DIR/packaging/deb/control.in" > "$DEB_ROOT/DEBIAN/control"

    # Copy maintainer scripts
    install -m 755 "$SCRIPT_DIR/packaging/deb/postinst" "$DEB_ROOT/DEBIAN/postinst"
    install -m 755 "$SCRIPT_DIR/packaging/deb/postrm" "$DEB_ROOT/DEBIAN/postrm"

    # Build the .deb
    cd "$WORK_DIR/electron-app"
    local DEB_FILE
    DEB_FILE="$(pwd)/claude-desktop-hardened_${VERSION}_${DEB_ARCH}.deb"
    fakeroot dpkg-deb --build "$DEB_ROOT" "$DEB_FILE"

    if [ -f "$DEB_FILE" ]; then
        log_ok "DEB package built successfully at: $DEB_FILE"
        echo "🎉 Done! Install with: sudo dpkg -i $DEB_FILE && sudo apt-get install -f"
    else
        log_error "Failed to build DEB package"
        exit 1
    fi
}
