#!/bin/bash
# Download and extract the OFFICIAL Anthropic Claude Desktop Linux .deb.
#
# BASE CHANGE (2026-07): this project used to download the Windows win32 nupkg
# and force it to run on Linux (which required extensive app.asar patching and
# native stubs). Anthropic now ships an official Linux .deb — a real Linux
# build — so we fetch that instead and repackage it with our hardening on top.
# No nupkg, no 7z, no wrestool.
#
# Requires: curl, dpkg-deb (or ar+tar fallback)
# Sets: VERSION; populates $WORK_DIR/deb-root with the extracted payload.

download_and_extract() {
    log_step "📥" "Downloading official Claude Desktop Linux .deb..."
    cd "$WORK_DIR"

    if [ -z "$CLAUDE_VERSION_PINNED" ]; then
        log_error "CLAUDE_VERSION is empty — cannot resolve the official .deb to download"
        exit 1
    fi

    local DEB_FILE="$WORK_DIR/claude-desktop-official.deb"
    if ! curl -fL -o "$DEB_FILE" "$CLAUDE_DOWNLOAD_URL"; then
        log_error "Failed to download official .deb from $CLAUDE_DOWNLOAD_URL"
        exit 1
    fi

    # Verify SHA256 against the pin (integrity + supply-chain guarantee).
    if [ -n "$CLAUDE_DEB_SHA256" ]; then
        local ACTUAL_SHA
        ACTUAL_SHA=$(sha256sum "$DEB_FILE" | cut -d' ' -f1)
        if [ "$ACTUAL_SHA" != "$CLAUDE_DEB_SHA256" ]; then
            log_error "SHA256 mismatch for official .deb"
            log_error "  expected: $CLAUDE_DEB_SHA256"
            log_error "  actual:   $ACTUAL_SHA"
            exit 1
        fi
        log_ok "Official .deb SHA256 verified"
    else
        log_warn "No SHA256 pin in CLAUDE_VERSION — skipping integrity check"
    fi

    VERSION="$CLAUDE_VERSION_PINNED"
    echo "📋 Claude Desktop (official Linux build): $VERSION"

    # Extract the .deb payload into $WORK_DIR/deb-root.
    log_step "📦" "Extracting official .deb payload..."
    local DEB_ROOT="$WORK_DIR/deb-root"
    rm -rf "$DEB_ROOT"
    mkdir -p "$DEB_ROOT"
    if command -v dpkg-deb >/dev/null 2>&1; then
        dpkg-deb -x "$DEB_FILE" "$DEB_ROOT" || { log_error "dpkg-deb extract failed"; exit 1; }
    else
        # Fallback for containers without dpkg (Fedora/Arch): ar + tar.
        local ARDIR="$WORK_DIR/deb-ar"
        rm -rf "$ARDIR"; mkdir -p "$ARDIR"; cd "$ARDIR"
        ar x "$DEB_FILE" || { log_error "ar extract failed (install binutils/dpkg)"; exit 1; }
        local data
        data=$(ls data.tar.* 2>/dev/null | head -1)
        if [ -z "$data" ]; then log_error "no data.tar.* in .deb"; exit 1; fi
        tar -xf "$data" -C "$DEB_ROOT" || { log_error "tar extract failed"; exit 1; }
        cd "$WORK_DIR"
    fi

    if [ ! -d "$DEB_ROOT/usr/lib/claude-desktop" ]; then
        log_error "Extracted .deb has no usr/lib/claude-desktop payload"
        exit 1
    fi
    log_ok "Official payload extracted to deb-root/usr/lib/claude-desktop"
}
