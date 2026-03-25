#!/bin/bash
# Download and extract the Claude Desktop nupkg.
# Requires: curl, 7z
# Sets: VERSION

download_and_extract() {
    log_step "📥" "Downloading Claude Desktop..."
    cd "$WORK_DIR"

    if [ "$DOWNLOAD_AS_NUPKG" = true ]; then
        NUPKG_FILE="$WORK_DIR/AnthropicClaude-${CLAUDE_VERSION_PINNED}-full.nupkg"
        if ! curl -L -o "$NUPKG_FILE" "$CLAUDE_DOWNLOAD_URL"; then
            log_error "Failed to download nupkg"
            exit 1
        fi
        # Verify SHA256 if provided
        if [ -n "$CLAUDE_NUPKG_SHA256" ]; then
            ACTUAL_SHA=$(sha256sum "$NUPKG_FILE" | cut -d' ' -f1)
            if [ "$ACTUAL_SHA" != "$CLAUDE_NUPKG_SHA256" ]; then
                log_error "SHA256 mismatch for nupkg (expected $CLAUDE_NUPKG_SHA256, got $ACTUAL_SHA)"
                exit 1
            fi
            log_ok "SHA256 verified"
        fi
        VERSION="$CLAUDE_VERSION_PINNED"
        echo "📋 Claude version: $VERSION (pinned)"
    else
        CLAUDE_EXE="$WORK_DIR/Claude-Setup-x64.exe"
        if ! curl -L -o "$CLAUDE_EXE" "$CLAUDE_DOWNLOAD_URL"; then
            log_error "Failed to download Claude Desktop installer"
            exit 1
        fi
        if ! 7z x -y "$CLAUDE_EXE"; then
            log_error "Failed to extract installer"
            exit 1
        fi
        NUPKG_FILE=$(find . -name "AnthropicClaude-*-full.nupkg" | head -1)
        if [ -z "$NUPKG_FILE" ]; then
            log_error "Could not find AnthropicClaude nupkg file"
            exit 1
        fi
        VERSION=$(echo "$NUPKG_FILE" | grep -oP 'AnthropicClaude-\K[0-9]+\.[0-9]+\.[0-9]+(?=-full\.nupkg)')
        echo "📋 Detected Claude version: $VERSION"
        if [ -n "$CLAUDE_VERSION_PINNED" ] && [ "$VERSION" != "$CLAUDE_VERSION_PINNED" ]; then
            log_warn "Downloaded version $VERSION differs from pinned $CLAUDE_VERSION_PINNED"
            echo "   Patches may not apply correctly. Update CLAUDE_VERSION to pin this version."
        fi
    fi
    log_ok "Download complete"

    # Extract resources
    log_step "📦" "Extracting nupkg..."
    if ! 7z x -y "$NUPKG_FILE"; then
        log_error "Failed to extract nupkg"
        exit 1
    fi
    log_ok "Resources extracted"
}
