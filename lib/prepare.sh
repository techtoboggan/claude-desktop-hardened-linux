#!/bin/bash
# Distro-agnostic app preparation for the HARDENED repackage.
#
# ============================================================================
# BASE CHANGE (2026-07): OFFICIAL Linux .deb, not the Windows nupkg
# ============================================================================
# This project now repackages the OFFICIAL Anthropic Claude Desktop Linux .deb
# (a native Linux build that bundles its own Electron + real @ant/claude-native
# binding). We DO NOT patch app.asar or inject native/cowork stubs anymore — all
# of that existed only to force the Windows build to run on Linux and is now
# obsolete. Our value-add is layered ON TOP of the unmodified official payload:
#
#   1. Enforced bubblewrap sandboxing (the launcher runs the app in a bwrap
#      namespace with a restricted view of $HOME and devices).
#   2. Supply-chain hardening (SHA256-pinned official .deb, SBOM, GPG-signed
#      checksums, SHA-pinned CI, source scanning — see CI).
#   3. Bundled Claude Code CLI + diagnostics.
#
# Requires: WORK_DIR, PKG_ROOT, INSTALL_DIR, INSTALL_LIB_DIR, SCRIPT_DIR, VERSION
# Requires: npm, node, python3, curl  (NO asar/electron/wrestool/7z — the .deb
# already ships a working Linux Electron app and its own icons)

prepare_app() {
    local DEB_ROOT="$WORK_DIR/deb-root"
    local SRC_APP="$DEB_ROOT/usr/lib/claude-desktop"
    if [ ! -d "$SRC_APP" ]; then
        log_error "Official payload not found at $SRC_APP — run download_and_extract first"
        exit 1
    fi

    local APP_DEST="$INSTALL_DIR/lib/$PACKAGE_NAME"
    mkdir -p "$APP_DEST" "$INSTALL_DIR/bin" \
             "$INSTALL_DIR/share/applications" "$INSTALL_DIR/share/icons" \
             "$INSTALL_DIR/share/$PACKAGE_NAME" "$INSTALL_DIR/share/metainfo"

    # -----------------------------------------------------------------------
    # 1. App payload — copy the official Linux build VERBATIM (no patching)
    # -----------------------------------------------------------------------
    log_step "📦" "Staging official Claude Desktop payload (unmodified)..."
    cp -a "$SRC_APP/." "$APP_DEST/"
    log_ok "Payload staged from official .deb (version $VERSION)"

    # -----------------------------------------------------------------------
    # 2. Icons — reuse the official build's icons under our app id
    # -----------------------------------------------------------------------
    log_step "🎨" "Installing icons..."
    if [ -d "$DEB_ROOT/usr/share/icons" ]; then
        cp -r "$DEB_ROOT/usr/share/icons/." "$INSTALL_DIR/share/icons/"
        # The official icons are named claude-desktop.png; our app id is
        # claude-desktop-hardened, so RENAME each to our name (don't leave the
        # original, or it ships as an unpackaged file / clashes with the
        # official package we conflict with).
        find "$INSTALL_DIR/share/icons" -type f -name 'claude-desktop.png' | while read -r f; do
            mv "$f" "$(dirname "$f")/claude-desktop-hardened.png"
        done
        log_ok "Icons installed"
    else
        log_warn "No icons found in official .deb"
    fi

    # -----------------------------------------------------------------------
    # 3. Claude Code CLI (bundled `claude` command) — the official .deb does
    #    not ship a standalone CLI, so we bundle one for terminal / Code use.
    # -----------------------------------------------------------------------
    log_step "📥" "Bundling Claude Code CLI..."
    local CLAUDE_CLI_DIR="$APP_DEST/claude-code"
    mkdir -p "$CLAUDE_CLI_DIR"
    if [ -z "${CLAUDE_CLI_VERSION:-}" ]; then
        CLAUDE_CLI_VERSION=$(curl -s https://registry.npmjs.org/@anthropic-ai/claude-code/latest \
            | python3 -c "import sys,json; print(json.load(sys.stdin).get('version','latest'))" 2>/dev/null || echo "latest")
        log_warn "Claude CLI version not pinned — using $CLAUDE_CLI_VERSION"
    fi
    echo "📋 Claude Code CLI: $CLAUDE_CLI_VERSION"
    echo "   node $(node --version 2>/dev/null || echo '?'), npm $(npm --version 2>/dev/null || echo '?')"
    # Don't suppress npm's output — a silent `>/dev/null 2>&1` here previously
    # hid the real error when the Arch toolchain broke CLI bundling.
    if ! ( cd "$CLAUDE_CLI_DIR" \
            && npm init -y >/dev/null 2>&1 \
            && npm install "@anthropic-ai/claude-code@${CLAUDE_CLI_VERSION}" --ignore-scripts ); then
        log_error "Failed to bundle Claude Code CLI (@anthropic-ai/claude-code@${CLAUDE_CLI_VERSION})"
        exit 1
    fi
    cat > "$INSTALL_DIR/bin/claude" << CLIEOF
#!/bin/bash
# Claude Code CLI — bundled with Claude Desktop (hardened)
NODE_PATH="${INSTALL_LIB_DIR}/claude-code/node_modules" \\
  exec node ${INSTALL_LIB_DIR}/claude-code/node_modules/@anthropic-ai/claude-code/cli.js "\$@"
CLIEOF
    chmod +x "$INSTALL_DIR/bin/claude"
    log_ok "Claude Code CLI bundled"

    # -----------------------------------------------------------------------
    # 4. Helper scripts + desktop entry + AppStream metainfo
    # -----------------------------------------------------------------------
    install -m 644 "$SCRIPT_DIR/lib/display-server.sh" "$INSTALL_DIR/share/$PACKAGE_NAME/display-server.sh"
    install -m 755 "$SCRIPT_DIR/scripts/doctor.sh"     "$INSTALL_DIR/share/$PACKAGE_NAME/doctor.sh"
    install -m 755 "$SCRIPT_DIR/scripts/focus.sh"      "$INSTALL_DIR/share/$PACKAGE_NAME/focus.sh"

    cat > "$INSTALL_DIR/share/applications/claude-desktop-hardened.desktop" << 'EOF'
[Desktop Entry]
Name=Claude (Hardened)
Comment=Claude Desktop for Linux — sandboxed with bubblewrap
GenericName=AI Assistant
Keywords=AI;Chat;Assistant;Claude;Code;LLM;
Exec=claude-desktop-hardened %u
Icon=claude-desktop-hardened
Type=Application
Terminal=false
StartupNotify=true
# The official binary derives its Wayland app_id / X11 WM_CLASS from its
# package.json desktopName (com.anthropic.Claude). We run it unmodified, so
# match that here for correct window grouping.
StartupWMClass=com.anthropic.Claude
SingleMainWindow=true
Categories=Utility;Development;
MimeType=x-scheme-handler/claude;
Actions=NewChat;NewCode;

[Desktop Action NewChat]
Name=New chat
Exec=claude-desktop-hardened claude://claude.ai/new

[Desktop Action NewCode]
Name=New Claude Code session
Exec=claude-desktop-hardened claude://code/new
EOF

    cat > "$INSTALL_DIR/share/metainfo/claude-desktop-hardened.metainfo.xml" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<component type="desktop-application">
  <id>io.github.techtoboggan.claude-desktop-hardened</id>
  <launchable type="desktop-id">claude-desktop-hardened.desktop</launchable>
  <name>Claude (Hardened)</name>
  <summary>The official Claude Desktop Linux build, hardened with bubblewrap sandboxing</summary>
  <metadata_license>CC0-1.0</metadata_license>
  <project_license>LicenseRef-proprietary</project_license>
  <description>
    <p>
      Repackages Anthropic's OFFICIAL Claude Desktop Linux build (.deb) for
      Fedora/RHEL and Arch, and adds enforced bubblewrap sandboxing plus
      supply-chain hardening (SHA256-pinned upstream, SBOM, GPG-signed
      checksums). The application payload is the official Linux build,
      unmodified; only the launcher and packaging are ours.
    </p>
  </description>
  <url type="homepage">https://github.com/techtoboggan/claude-desktop-hardened-linux</url>
  <url type="bugtracker">https://github.com/techtoboggan/claude-desktop-hardened-linux/issues</url>
  <developer id="io.github.techtoboggan"><name>Tristan (techtoboggan)</name></developer>
  <content_rating type="oars-1.1"/>
  <categories><category>Utility</category><category>Development</category></categories>
  <releases><release version="${VERSION}" date="$(date -u +%Y-%m-%d)"/></releases>
</component>
EOF
    log_ok "Desktop entry + AppStream metainfo written"

    # -----------------------------------------------------------------------
    # 5. Hardened launcher — enforced bubblewrap sandbox around the app
    # -----------------------------------------------------------------------
    log_step "🛡️" "Generating hardened (bubblewrap) launcher..."
    _write_launcher "$INSTALL_DIR/bin/claude-desktop-hardened"
    chmod +x "$INSTALL_DIR/bin/claude-desktop-hardened"
    log_ok "Hardened launcher installed"
}

# Writes the launcher to $1. INSTALL_LIB_DIR is baked in at build time.
_write_launcher() {
    local out="$1"
    cat > "$out" << LAUNCHEREOF
#!/bin/bash
# ============================================================================
# Claude Desktop (Hardened) launcher
# ============================================================================
# Runs Anthropic's OFFICIAL Claude Desktop Linux binary inside a bubblewrap
# sandbox that restricts its view of your home directory and devices. The app
# payload is unmodified; this wrapper is the security layer.
#
# Escape hatches:
#   CLAUDE_NO_SANDBOX=1   run the app directly, without bubblewrap
#   (bubblewrap missing)  falls back to a direct launch with a warning
# ============================================================================
set -u

APP_DIR="${INSTALL_LIB_DIR}"
APP_BIN="\$APP_DIR/claude-desktop"
SHARE_DIR="\${CLAUDE_SHARE_DIR:-${INSTALL_LIB_DIR}/../../share/claude-desktop-hardened}"

# Wayland/X11 app_id so the compositor groups windows under our .desktop entry.
export CHROME_DESKTOP="claude-desktop-hardened.desktop"
if [ -n "\${WAYLAND_DISPLAY:-}" ] || [ "\${XDG_SESSION_TYPE:-}" = "wayland" ]; then
    export CLAUDE_DISPLAY_SERVER="wayland"
    export ELECTRON_OZONE_PLATFORM_HINT="\${ELECTRON_OZONE_PLATFORM_HINT:-auto}"
elif [ -n "\${DISPLAY:-}" ]; then
    export CLAUDE_DISPLAY_SERVER="x11"
else
    export CLAUDE_DISPLAY_SERVER="headless"
fi

# Chromium keyring backend: fall back to basic store if no Secret Service.
KEYRING_FLAG=""
if command -v dbus-send >/dev/null 2>&1; then
    if ! dbus-send --session --print-reply --dest=org.freedesktop.DBus \\
        /org/freedesktop/DBus org.freedesktop.DBus.ListNames 2>/dev/null | \\
        grep -q "org.freedesktop.secrets"; then
        KEYRING_FLAG="--password-store=basic"
    fi
else
    KEYRING_FLAG="--password-store=basic"
fi

# Sub-commands (diagnostics / window focus) handled before launch.
case "\${1:-}" in
    --doctor) exec "\$SHARE_DIR/doctor.sh" ;;
    --focus)  exec "\$SHARE_DIR/focus.sh" ;;
esac

XRD="\${XDG_RUNTIME_DIR:-/run/user/\$(id -u)}"
CFG="\${XDG_CONFIG_HOME:-\$HOME/.config}"
CACHE="\${XDG_CACHE_HOME:-\$HOME/.cache}"
# systemd-resolved / NetworkManager make /etc/resolv.conf a symlink into /run.
# Bind that target dir so DNS resolves inside the sandbox — otherwise the
# symlink dangles and the app "can't connect to Claude".
RESOLV_DIR="\$(dirname "\$(readlink -f /etc/resolv.conf 2>/dev/null || echo /etc/resolv.conf)")"

run_direct() {
    # Electron's own sandbox (setuid chrome-sandbox); used when bwrap is off.
    exec "\$APP_BIN" \$KEYRING_FLAG "\$@"
}

if [ "\${CLAUDE_NO_SANDBOX:-0}" = "1" ] || ! command -v bwrap >/dev/null 2>&1; then
    [ "\${CLAUDE_NO_SANDBOX:-0}" = "1" ] || echo "[claude-hardened] bubblewrap not found — launching WITHOUT sandbox" >&2
    run_direct "\$@"
fi

# Preserve the user's arguments (e.g. a claude:// URL) before we build opts.
USER_ARGS=("\$@")

# Shared /tmp for all Claude instances. Electron/Chromium put the single-instance
# SingletonSocket under /tmp; if /tmp were a private tmpfs per sandbox, the
# OAuth-callback instance couldn't reach the running instance's socket and would
# launch a second app (+ second tray). A per-user dir bound to /tmp keeps
# instances talking to each other without exposing the host's /tmp.
CDH_TMP="\$CACHE/claude-desktop/tmp"

# Ensure the app's own writable dirs exist before binding them in.
mkdir -p "\$CFG/Claude" "\$CACHE/claude-desktop" "\$CDH_TMP" "\$HOME/.claude" 2>/dev/null || true

# --- bubblewrap profile ---------------------------------------------------
# Claude Desktop is an agentic app: Cowork/Code sessions and MCP servers must
# be able to run your tools and work with your files. So the profile is
# DEFAULT-ALLOW \$HOME, but MASKS credential/secret locations with empty tmpfs
# (ssh, gnupg, cloud creds, browser profiles, keyrings). System is read-only,
# devices are limited to GPU/KVM/sound, and user/cgroup namespaces isolate the
# app. Network is shared (the app needs it). This protects your secrets and the
# system from a compromised renderer/MCP without breaking the tool.
#
# NOTE: we deliberately DON'T --unshare-pid or --unshare-uts. Electron's
# single-instance lock records "<hostname>-<pid>"; a private PID namespace makes
# every instance PID 2, and a private UTS namespace changes the hostname — both
# break single-instance forwarding, so the OAuth claude:// callback would spawn
# a second app instead of returning to the running one.
BWRAP_OPTS=(
    --die-with-parent
    --unshare-user-try --unshare-cgroup-try
    --new-session
    --share-net
    --ro-bind /usr /usr
    --symlink usr/lib /lib --symlink usr/lib64 /lib64
    --symlink usr/bin /bin --symlink usr/sbin /sbin
    --ro-bind-try /etc /etc
    --ro-bind-try "\$RESOLV_DIR" "\$RESOLV_DIR"
    --ro-bind-try /opt /opt
    --ro-bind-try /sys /sys
    --proc /proc
    --dev /dev
    --dev-bind-try /dev/dri /dev/dri
    --dev-bind-try /dev/kvm /dev/kvm
    --dev-bind-try /dev/snd /dev/snd
    --dev-bind-try /dev/uinput /dev/uinput
    --bind "\$CDH_TMP" /tmp
    --ro-bind-try /tmp/.X11-unix /tmp/.X11-unix
    --bind "\$HOME" "\$HOME"
    --bind-try "\$XRD" "\$XRD"
    --ro-bind-try /run/dbus /run/dbus
    --setenv HOME "\$HOME"
    # Mask credential/secret locations (empty tmpfs overlays the real dirs).
    --tmpfs "\$HOME/.ssh"
    --tmpfs "\$HOME/.gnupg"
    --tmpfs "\$HOME/.aws"
    --tmpfs "\$HOME/.azure"
    --tmpfs "\$HOME/.config/gcloud"
    --tmpfs "\$HOME/.kube"
    --tmpfs "\$HOME/.docker"
    --tmpfs "\$HOME/.pki"
    --tmpfs "\$HOME/.local/share/keyrings"
    --tmpfs "\$HOME/.mozilla"
    --tmpfs "\$HOME/.config/google-chrome"
    --tmpfs "\$HOME/.config/chromium"
    --tmpfs "\$HOME/.config/BraveSoftware"
    --tmpfs "\$HOME/.config/Slack"
)

# bwrap runs the app; --no-sandbox disables Electron's own (nested) sandbox
# because bwrap already provides the namespace isolation. \$KEYRING_FLAG is
# intentionally unquoted (may be empty). User args come last.
KEYRING_ARGS=()
[ -n "\$KEYRING_FLAG" ] && KEYRING_ARGS=("\$KEYRING_FLAG")
exec bwrap "\${BWRAP_OPTS[@]}" "\$APP_BIN" --no-sandbox "\${KEYRING_ARGS[@]}" "\${USER_ARGS[@]}"
LAUNCHEREOF
}
