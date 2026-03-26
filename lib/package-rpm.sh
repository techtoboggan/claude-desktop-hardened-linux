#!/bin/bash
# RPM packaging via rpmbuild.

set_lib_dir() {
    export INSTALL_LIB_DIR="/usr/lib64/claude-desktop"
}

build_package() {
    log_step "📦" "Building RPM package..."

    # Generate spec from template
    local SPEC_IN="$SCRIPT_DIR/packaging/rpm/claude-desktop.spec.in"
    local SPEC_OUT="$WORK_DIR/claude-desktop.spec"

    sed -e "s|@@VERSION@@|${VERSION}|g" \
        -e "s|@@ARCHITECTURE@@|${ARCHITECTURE}|g" \
        -e "s|@@INSTALL_DIR@@|${INSTALL_DIR}|g" \
        -e "s|@@LIB_DIR@@|/usr/lib64|g" \
        -e "s|@@DATE@@|$(date '+%a %b %d %Y')|g" \
        -e "s|@@MAINTAINER@@|${MAINTAINER}|g" \
        "$SPEC_IN" > "$SPEC_OUT"

    # rpmbuild directories
    mkdir -p "${WORK_DIR}"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

    cd "$WORK_DIR/electron-app"
    RPM_FILE="$(pwd)/${ARCHITECTURE}/claude-desktop-${VERSION}-1.${ARCHITECTURE}.rpm"
    if rpmbuild -bb \
        --define "_topdir ${WORK_DIR}" \
        --define "_rpmdir $(pwd)" \
        --define "dist %{nil}" \
        "${SPEC_OUT}"; then
        log_ok "RPM package built successfully at: $RPM_FILE"
        echo "🎉 Done! Install with: dnf install $RPM_FILE"
    else
        log_error "Failed to build RPM package"
        exit 1
    fi
}
