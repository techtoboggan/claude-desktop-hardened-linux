#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Version pin — read from CLAUDE_VERSION (commit this file to update the pin).
# Line 1 = version string, line 2 (optional) = SHA256 of the nupkg for verification.
CLAUDE_VERSION_PINNED=""
CLAUDE_NUPKG_SHA256=""
if [ -f "$SCRIPT_DIR/CLAUDE_VERSION" ]; then
    CLAUDE_VERSION_PINNED=$(sed -n '1p' "$SCRIPT_DIR/CLAUDE_VERSION" | tr -d '[:space:]')
    CLAUDE_NUPKG_SHA256=$(sed -n '2p' "$SCRIPT_DIR/CLAUDE_VERSION" | tr -d '[:space:]')
fi

# Download URL — if pinned, use the specific version; otherwise download latest.
if [ -n "$CLAUDE_VERSION_PINNED" ]; then
    CLAUDE_DOWNLOAD_URL="https://downloads.claude.ai/releases/win32/x64/AnthropicClaude-${CLAUDE_VERSION_PINNED}-full.nupkg"
    DOWNLOAD_AS_NUPKG=true
else
    CLAUDE_DOWNLOAD_URL="https://storage.googleapis.com/osprey-downloads-c02f6a0d-347c-492b-a752-3e0651722e97/nest-win-x64/Claude-Setup-x64.exe"
    DOWNLOAD_AS_NUPKG=false
fi

# Inclusive check for Fedora-based system
is_fedora_based() {
    if [ -f "/etc/fedora-release" ]; then
        return 0
    fi
    
    if [ -f "/etc/os-release" ]; then
        grep -qi "fedora" /etc/os-release && return 0
    fi
    
    # Not a Fedora-based system
    return 1
}

if ! is_fedora_based; then
    echo "❌ This script requires a Fedora-based Linux distribution"
    exit 1
fi

# Check for root/sudo
IS_SUDO=false
if [ "$EUID" -eq 0 ]; then
    IS_SUDO=true
    # Check if running via sudo (and not directly as root)
    if [ -n "$SUDO_USER" ]; then
        ORIGINAL_USER="$SUDO_USER"
        ORIGINAL_HOME=$(eval echo ~$ORIGINAL_USER)
    else
        # Running directly as root, no original user context
        ORIGINAL_USER="root"
        ORIGINAL_HOME="/root"
    fi
else
    echo "Please run with sudo to install dependencies"
    exit 1
fi

# Preserve NVM path if running under sudo and NVM exists for the original user
if [ "$IS_SUDO" = true ] && [ "$ORIGINAL_USER" != "root" ] && [ -d "$ORIGINAL_HOME/.nvm" ]; then
    echo "Found NVM installation for user $ORIGINAL_USER, attempting to preserve npm/npx path..."
    # Source NVM script to set up NVM environment variables temporarily
    export NVM_DIR="$ORIGINAL_HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh" # This loads nvm

    # Find the path to the currently active or default Node version's bin directory
    # nvm_find_node_version might not be available, try finding the latest installed version
    NODE_BIN_PATH=$(find "$NVM_DIR/versions/node" -maxdepth 2 -type d -name 'bin' | sort -V | tail -n 1)

    if [ -n "$NODE_BIN_PATH" ] && [ -d "$NODE_BIN_PATH" ]; then
        echo "Adding $NODE_BIN_PATH to PATH"
        export PATH="$NODE_BIN_PATH:$PATH"
    else
        echo "Warning: Could not determine NVM Node bin path. npm/npx might not be found."
    fi
fi

# Print system information
echo "System Information:"
echo "Distribution: $(cat /etc/os-release | grep "PRETTY_NAME" | cut -d'"' -f2)"
echo "Fedora version: $(cat /etc/fedora-release)"

# Function to check if a command exists
check_command() {
    if ! command -v "$1" &> /dev/null; then
        echo "❌ $1 not found"
        return 1
    else
        echo "✓ $1 found"
        return 0
    fi
}

# Check and install dependencies
echo "Checking dependencies..."
DEPS_TO_INSTALL=""

# Check system package dependencies
for cmd in sqlite3 7z wget wrestool icotool convert npx rpm rpmbuild python3 curl; do
    if ! check_command "$cmd"; then
        case "$cmd" in
            "sqlite3")
                DEPS_TO_INSTALL="$DEPS_TO_INSTALL sqlite3"
                ;;
            "7z")
                DEPS_TO_INSTALL="$DEPS_TO_INSTALL p7zip-plugins"
                ;;
            "wget")
                DEPS_TO_INSTALL="$DEPS_TO_INSTALL wget"
                ;;
            "wrestool"|"icotool")
                DEPS_TO_INSTALL="$DEPS_TO_INSTALL icoutils"
                ;;
            "convert")
                DEPS_TO_INSTALL="$DEPS_TO_INSTALL ImageMagick"
                ;;
            "npx")
                DEPS_TO_INSTALL="$DEPS_TO_INSTALL nodejs npm"
                ;;
            "rpm")
                DEPS_TO_INSTALL="$DEPS_TO_INSTALL rpm"
                ;;
            "rpmbuild")
                DEPS_TO_INSTALL="$DEPS_TO_INSTALL rpmbuild"
                ;;
            "python3")
                DEPS_TO_INSTALL="$DEPS_TO_INSTALL python3"
                ;;
            "curl")
                DEPS_TO_INSTALL="$DEPS_TO_INSTALL curl"
        esac
    fi
done

# Install system dependencies if any
if [ ! -z "$DEPS_TO_INSTALL" ]; then
    echo "Installing system dependencies: $DEPS_TO_INSTALL"
    dnf install -y $DEPS_TO_INSTALL
    echo "System dependencies installed successfully"
fi

# Install electron globally via npm if not present
if ! check_command "electron"; then
    echo "Installing electron via npm..."
    npm install -g electron
    if ! check_command "electron"; then
        echo "Failed to install electron. Please install it manually:"
        echo "sudo npm install -g electron"
        exit 1
    fi
    echo "Electron installed successfully"
fi

PACKAGE_NAME="claude-desktop"
ARCHITECTURE=$(uname -m)
DISTRIBUTION=$(rpm --eval %{?dist})
MAINTAINER="Claude Desktop Linux Maintainers"
DESCRIPTION="Claude Desktop for Linux"

# Create working directories
WORK_DIR="$(pwd)/build"
FEDORA_ROOT="$WORK_DIR/fedora-package"
INSTALL_DIR="$FEDORA_ROOT/usr"

# Clean previous build
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
mkdir -p "$FEDORA_ROOT/FEDORA"
mkdir -p "$INSTALL_DIR/lib/$PACKAGE_NAME"
mkdir -p "$INSTALL_DIR/share/applications"
mkdir -p "$INSTALL_DIR/share/icons"
mkdir -p "$INSTALL_DIR/bin"

# Install asar if needed
if ! command -v asar > /dev/null 2>&1; then
    echo "Installing asar package globally..."
    npm install -g asar
fi

# Download Claude Desktop
echo "📥 Downloading Claude Desktop..."
cd "$WORK_DIR"
if [ "$DOWNLOAD_AS_NUPKG" = true ]; then
    NUPKG_FILE="$WORK_DIR/AnthropicClaude-${CLAUDE_VERSION_PINNED}-full.nupkg"
    if ! curl -L -o "$NUPKG_FILE" "$CLAUDE_DOWNLOAD_URL"; then
        echo "❌ Failed to download nupkg"
        exit 1
    fi
    # Verify SHA256 if provided
    if [ -n "$CLAUDE_NUPKG_SHA256" ]; then
        ACTUAL_SHA=$(sha256sum "$NUPKG_FILE" | cut -d' ' -f1)
        if [ "$ACTUAL_SHA" != "$CLAUDE_NUPKG_SHA256" ]; then
            echo "❌ SHA256 mismatch for nupkg (expected $CLAUDE_NUPKG_SHA256, got $ACTUAL_SHA)"
            exit 1
        fi
        echo "✓ SHA256 verified"
    fi
    VERSION="$CLAUDE_VERSION_PINNED"
    echo "📋 Claude version: $VERSION (pinned)"
else
    CLAUDE_EXE="$WORK_DIR/Claude-Setup-x64.exe"
    if ! curl -L -o "$CLAUDE_EXE" "$CLAUDE_DOWNLOAD_URL"; then
        echo "❌ Failed to download Claude Desktop installer"
        exit 1
    fi
    if ! 7z x -y "$CLAUDE_EXE"; then
        echo "❌ Failed to extract installer"
        exit 1
    fi
    NUPKG_FILE=$(find . -name "AnthropicClaude-*-full.nupkg" | head -1)
    if [ -z "$NUPKG_FILE" ]; then
        echo "❌ Could not find AnthropicClaude nupkg file"
        exit 1
    fi
    VERSION=$(echo "$NUPKG_FILE" | grep -oP 'AnthropicClaude-\K[0-9]+\.[0-9]+\.[0-9]+(?=-full\.nupkg)')
    echo "📋 Detected Claude version: $VERSION"
    if [ -n "$CLAUDE_VERSION_PINNED" ] && [ "$VERSION" != "$CLAUDE_VERSION_PINNED" ]; then
        echo "⚠️  WARNING: Downloaded version $VERSION differs from pinned $CLAUDE_VERSION_PINNED"
        echo "   Patches may not apply correctly. Update CLAUDE_VERSION to pin this version."
    fi
fi
echo "✓ Download complete"

# Extract resources
echo "📦 Extracting nupkg..."
if ! 7z x -y "$NUPKG_FILE"; then
    echo "❌ Failed to extract nupkg"
    exit 1
fi
echo "✓ Resources extracted"

# Extract and convert icons
echo "🎨 Processing icons..."
if ! wrestool -x -t 14 "lib/net45/claude.exe" -o claude.ico; then
    echo "❌ Failed to extract icons from exe"
    exit 1
fi

if ! icotool -x claude.ico; then
    echo "❌ Failed to convert icons"
    exit 1
fi
echo "✓ Icons processed"

# Map icon sizes to their corresponding extracted files
declare -A icon_files=(
    ["16"]="claude_13_16x16x32.png"
    ["24"]="claude_11_24x24x32.png"
    ["32"]="claude_10_32x32x32.png"
    ["48"]="claude_8_48x48x32.png"
    ["64"]="claude_7_64x64x32.png"
    ["256"]="claude_6_256x256x32.png"
)

# Install icons
for size in 16 24 32 48 64 256; do
    icon_dir="$INSTALL_DIR/share/icons/hicolor/${size}x${size}/apps"
    mkdir -p "$icon_dir"
    if [ -f "${icon_files[$size]}" ]; then
        echo "Installing ${size}x${size} icon..."
        install -Dm 644 "${icon_files[$size]}" "$icon_dir/claude-desktop.png"
    else
        echo "Warning: Missing ${size}x${size} icon"
    fi
done

# Process app.asar
mkdir -p electron-app
cp "lib/net45/resources/app.asar" electron-app/
cp -r "lib/net45/resources/app.asar.unpacked" electron-app/

cd electron-app
npx asar extract app.asar app.asar.contents || { echo "asar extract failed"; exit 1; }

# Replace native module with enhanced Linux stub (with Cowork support)
echo "🔧 Installing claude-native stub..."
cp "$SCRIPT_DIR/stubs/claude-native/index.js" app.asar.contents/node_modules/claude-native/index.js

# Install Cowork stubs
echo "🔧 Installing Cowork stubs..."
mkdir -p app.asar.contents/node_modules/claude-swift-stub
cp "$SCRIPT_DIR/stubs/claude-swift-stub/index.js" app.asar.contents/node_modules/claude-swift-stub/index.js

mkdir -p app.asar.contents/node_modules/cowork
for f in "$SCRIPT_DIR"/stubs/cowork/*.js; do
    cp "$f" "app.asar.contents/node_modules/cowork/$(basename "$f")"
done

# Run the Cowork platform gate patcher
echo "🔧 Patching for Cowork enablement..."
python3 "$SCRIPT_DIR/enable-cowork.py" app.asar.contents

# Copy Tray icons and invert RGB to white (Windows ships black template icons;
# Linux system trays are dark, so we flip RGB channels while preserving alpha).
mkdir -p app.asar.contents/resources
cp ../lib/net45/resources/Tray* app.asar.contents/resources/ 2>/dev/null || true
for tray_src in app.asar.contents/resources/Tray*.png; do
    [ -f "$tray_src" ] || continue
    convert "$tray_src" -channel RGB -negate "$tray_src" 2>/dev/null && \
        echo "  Tray icon → white: $(basename "$tray_src")" || true
done

# Copy the 256×256 icon so it's available for window/dock injection at runtime
if [ -f "$WORK_DIR/claude_6_256x256x32.png" ]; then
    cp "$WORK_DIR/claude_6_256x256x32.png" app.asar.contents/resources/icon.png
fi

# Repackage app.asar
mkdir -p app.asar.contents/resources/i18n/
cp ../lib/net45/resources/*.json app.asar.contents/resources/i18n/

# Patch window decorations: titleBarStyle:"hidden" + titleBarOverlay for Linux CSD
# (native close/min/max inside the app's content area, like Firefox on Linux)
echo "🔧 Patching window decorations..."
node "$SCRIPT_DIR/scripts/patch-window.js" app.asar.contents

# Inject startup code: hide menu bar, set window icon, inject Claude icon into title bar
echo "🔧 Injecting startup patches..."
MAIN_JS="app.asar.contents/.vite/build/index.js"
if [ -f "$MAIN_JS" ]; then
    cat > /tmp/claude-prepend.js << 'PREPENDJS'
const{app:_capp,Menu:_cMenu,nativeImage:_cNI}=require("electron");
const _cPath=require("path");

// Load icon once; resize to 48px for in-app title bar injection.
const _iconPath=_cPath.join(__dirname,"..","..","resources","icon.png");
const _iconFull=_cNI.createFromPath(_iconPath);
const _iconSmall=_iconFull.isEmpty()?_iconFull:_iconFull.resize({width:48,height:48});
const _iconDataUrl=_iconSmall.isEmpty()?null:_iconSmall.toDataURL();

if(process.platform==="linux"){
  // Block all menu-bar creation before any app code runs.
  const _origSetMenu=_cMenu.setApplicationMenu.bind(_cMenu);
  _cMenu.setApplicationMenu=()=>_origSetMenu(null);
}

_capp.on("ready",()=>{
  _cMenu.setApplicationMenu(null);
  try{if(!_iconFull.isEmpty()&&_capp.setIcon)_capp.setIcon(_iconFull);}catch(ex){}
});

_capp.on("browser-window-created",(e,w)=>{
  try{if(!_iconFull.isEmpty())w.setIcon(_iconFull);}catch(ex){}

  if(process.platform!=="linux"||!_iconDataUrl)return;

  // CSS: fixed draggable icon wrapper top-left, 42×44px matching titleBarOverlay height.
  const _css=[
    "#_cld_icon{",
      "position:fixed;top:0;left:0;",
      "width:42px;height:44px;",
      "z-index:2147483647;",
      "display:flex;align-items:center;justify-content:center;",
      "-webkit-app-region:drag;",
      "user-select:none;box-sizing:border-box;padding:9px;",
    "}",
    "#_cld_icon img{",
      "width:100%;height:100%;",
      "pointer-events:none;-webkit-app-region:no-drag;",
      "object-fit:contain;",
      "filter:drop-shadow(0 1px 3px rgba(0,0,0,0.45));",
    "}",
  ].join("");

  // JS: wait for first top-left nav button, shift its container right, append icon.
  const _js=[
    "(function(){",
      "if(document.getElementById('_cld_icon'))return;",
      "const el=document.createElement('div');",
      "el.id='_cld_icon';",
      "const img=document.createElement('img');",
      "img.src='",_iconDataUrl,"';",
      "img.alt='Claude';",
      "el.appendChild(img);",
      "const place=()=>{",
        "const all=Array.from(document.querySelectorAll('button,[role=button],[role=tab]'));",
        "const tl=all.find(b=>{const r=b.getBoundingClientRect();",
          "return r.top>=0&&r.top<52&&r.left>=0&&r.left<100&&r.width>0&&r.height>0;});",
        "if(!tl)return false;",
        "const p=tl.parentElement;",
        "if(p&&!p.dataset.cldShifted){",
          "p.dataset.cldShifted='1';",
          "const pl=parseInt(getComputedStyle(p).paddingLeft)||0;",
          "p.style.paddingLeft=(pl+44)+'px';",
        "}",
        "document.documentElement.appendChild(el);",
        "return true;",
      "};",
      "if(!place()){",
        "const obs=new MutationObserver(()=>{if(place())obs.disconnect();});",
        "obs.observe(document.documentElement,{childList:true,subtree:true});",
        "setTimeout(()=>obs.disconnect(),20000);",
      "}",
    "})();",
  ].join("");

  const inject=()=>{
    const b=w.getBounds();
    if(b.width<500||b.height<300)return;
    w.webContents.insertCSS(_css).catch(()=>{});
    w.webContents.executeJavaScript(_js).catch(()=>{});
  };

  w.webContents.on("dom-ready",inject);
  w.webContents.on("did-navigate-in-page",inject);
});
PREPENDJS
    cat /tmp/claude-prepend.js "$MAIN_JS" > /tmp/claude-combined.js
    mv /tmp/claude-combined.js "$MAIN_JS"
    rm -f /tmp/claude-prepend.js
    echo "  Menu bar hidden + icon injection installed"
fi

npx asar pack app.asar.contents app.asar || { echo "asar pack failed"; exit 1; }

# Install native module stub in unpacked directory
mkdir -p "$INSTALL_DIR/lib/$PACKAGE_NAME/app.asar.unpacked/node_modules/claude-native"
cp "$SCRIPT_DIR/stubs/claude-native/index.js" \
   "$INSTALL_DIR/lib/$PACKAGE_NAME/app.asar.unpacked/node_modules/claude-native/index.js"

# Install Cowork stubs in unpacked directory
mkdir -p "$INSTALL_DIR/lib/$PACKAGE_NAME/app.asar.unpacked/node_modules/claude-swift-stub"
cp "$SCRIPT_DIR/stubs/claude-swift-stub/index.js" \
   "$INSTALL_DIR/lib/$PACKAGE_NAME/app.asar.unpacked/node_modules/claude-swift-stub/index.js"

mkdir -p "$INSTALL_DIR/lib/$PACKAGE_NAME/app.asar.unpacked/node_modules/cowork"
for f in "$SCRIPT_DIR"/stubs/cowork/*.js; do
    cp "$f" "$INSTALL_DIR/lib/$PACKAGE_NAME/app.asar.unpacked/node_modules/cowork/$(basename "$f")"
done

# Download and bundle Claude Code CLI
echo "📥 Downloading Claude Code CLI..."
CLAUDE_CLI_DIR="$INSTALL_DIR/lib/$PACKAGE_NAME/claude-code"
mkdir -p "$CLAUDE_CLI_DIR"

# Get the latest version from npm registry
CLAUDE_CLI_VERSION=$(curl -s https://registry.npmjs.org/@anthropic-ai/claude-code/latest | python3 -c "import sys,json; print(json.load(sys.stdin).get('version','latest'))" 2>/dev/null || echo "latest")
echo "📋 Claude Code CLI version: $CLAUDE_CLI_VERSION"

# Install Claude Code CLI to the bundle directory
cd "$CLAUDE_CLI_DIR"
npm init -y > /dev/null 2>&1
npm install "@anthropic-ai/claude-code@${CLAUDE_CLI_VERSION}" --save > /dev/null 2>&1

# Create a wrapper script for the bundled CLI
mkdir -p "$INSTALL_DIR/bin"
cat > "$INSTALL_DIR/bin/claude" << 'CLIEOF'
#!/bin/bash
# Claude Code CLI - bundled with Claude Desktop for Linux
NODE_PATH="/usr/lib64/claude-desktop/claude-code/node_modules" \
  exec node /usr/lib64/claude-desktop/claude-code/node_modules/@anthropic-ai/claude-code/cli.js "$@"
CLIEOF
chmod +x "$INSTALL_DIR/bin/claude"

cd "$WORK_DIR/electron-app"
echo "✓ Claude Code CLI bundled"

# Copy app files
cp app.asar "$INSTALL_DIR/lib/$PACKAGE_NAME/"
cp -r app.asar.unpacked "$INSTALL_DIR/lib/$PACKAGE_NAME/"

# Create desktop entry
cat > "$INSTALL_DIR/share/applications/claude-desktop.desktop" << EOF
[Desktop Entry]
Name=Claude
Exec=claude-desktop %u
Icon=claude-desktop
Type=Application
Terminal=false
Categories=Office;Utility;
MimeType=x-scheme-handler/claude;
StartupWMClass=Claude
EOF

# Create launcher script with Wayland detection, keyring support, and logging
cat > "$INSTALL_DIR/bin/claude-desktop" << 'LAUNCHEREOF'
#!/bin/bash

# Detect Wayland
if [ -n "$WAYLAND_DISPLAY" ] || [ "$XDG_SESSION_TYPE" = "wayland" ]; then
    export ELECTRON_OZONE_PLATFORM_HINT="${ELECTRON_OZONE_PLATFORM_HINT:-wayland}"
fi

# Detect keyring provider via D-Bus for credential storage
KEYRING_FLAG=""
if command -v dbus-send >/dev/null 2>&1; then
    if ! dbus-send --session --print-reply --dest=org.freedesktop.DBus \
        /org/freedesktop/DBus org.freedesktop.DBus.ListNames 2>/dev/null | \
        grep -q "org.freedesktop.secrets"; then
        KEYRING_FLAG="--password-store=basic"
    fi
else
    KEYRING_FLAG="--password-store=basic"
fi

LOG_FILE="$HOME/claude-desktop-launcher.log"

exec electron /usr/lib64/claude-desktop/app.asar \
    --ozone-platform-hint=auto \
    --enable-logging=file \
    --log-file="$LOG_FILE" \
    --log-level=INFO \
    $KEYRING_FLAG \
    "$@"
LAUNCHEREOF
chmod +x "$INSTALL_DIR/bin/claude-desktop"

# Create RPM spec file
cat > "$WORK_DIR/claude-desktop.spec" << EOF
Name:           claude-desktop
Version:        ${VERSION}
Release:        1%{?dist}
Summary:        Claude Desktop for Linux
License:        Proprietary
URL:            https://www.anthropic.com
BuildArch:      ${ARCHITECTURE}
Requires:       nodejs >= 18.0.0, npm, p7zip, xdg-utils
Recommends:     qemu-kvm, bubblewrap, socat, gnome-keyring

%description
Claude is an AI assistant from Anthropic.
This package provides the desktop interface for Claude with Cowork
(Local Agent Mode) support for Linux. Includes bundled Claude Code CLI.

%install
mkdir -p %{buildroot}/usr/lib64/%{name}
mkdir -p %{buildroot}/usr/bin
mkdir -p %{buildroot}/usr/share/applications
mkdir -p %{buildroot}/usr/share/icons

# Copy files from the INSTALL_DIR
cp -r ${INSTALL_DIR}/lib/%{name}/* %{buildroot}/usr/lib64/%{name}/
cp -r ${INSTALL_DIR}/bin/* %{buildroot}/usr/bin/
cp -r ${INSTALL_DIR}/share/applications/* %{buildroot}/usr/share/applications/
cp -r ${INSTALL_DIR}/share/icons/* %{buildroot}/usr/share/icons/

%files
%{_bindir}/claude-desktop
%{_bindir}/claude
%{_libdir}/%{name}
%{_datadir}/applications/claude-desktop.desktop
%{_datadir}/icons/hicolor/*/apps/claude-desktop.png

%post
# Update icon caches
gtk-update-icon-cache -f -t %{_datadir}/icons/hicolor || :
# Force icon theme cache rebuild
touch -h %{_datadir}/icons/hicolor >/dev/null 2>&1 || :
update-desktop-database %{_datadir}/applications || :

# Ensure Claude Code CLI wrapper is executable
chmod +x %{_bindir}/claude 2>/dev/null || :

# Set correct permissions for chrome-sandbox
echo "Setting chrome-sandbox permissions..."
SANDBOX_PATH=""
# Check for sandbox in locally packaged electron first
if [ -f "/usr/lib64/claude-desktop/app.asar.unpacked/node_modules/electron/dist/chrome-sandbox" ]; then
    SANDBOX_PATH="/usr/lib64/claude-desktop/app.asar.unpacked/node_modules/electron/dist/chrome-sandbox"

elif [ -n "$SUDO_USER" ]; then
    # Running via sudo: try to get electron from the invoking user's environment
    if su - "$SUDO_USER" -c "command -v electron >/dev/null 2>&1"; then
        ELECTRON_PATH=$(su - "$SUDO_USER" -c "command -v electron")

        POTENTIAL_SANDBOX="\$(dirname "\$(dirname "\$ELECTRON_PATH")")/lib/node_modules/electron/dist/chrome-sandbox"
        if [ -f "\$POTENTIAL_SANDBOX" ]; then
            SANDBOX_PATH="\$POTENTIAL_SANDBOX"
        fi
    fi
else
    # Running directly as root (no SUDO_USER); attempt to find electron in root's PATH
    if command -v electron >/dev/null 2>&1; then
        ELECTRON_PATH=$(command -v electron)
        POTENTIAL_SANDBOX="\$(dirname "\$(dirname "\$ELECTRON_PATH")")/lib/node_modules/electron/dist/chrome-sandbox"
        if [ -f "\$POTENTIAL_SANDBOX" ]; then
            SANDBOX_PATH="\$POTENTIAL_SANDBOX"
        fi
    fi
fi

if [ -n "\$SANDBOX_PATH" ] && [ -f "\$SANDBOX_PATH" ]; then
    echo "Found chrome-sandbox at: \$SANDBOX_PATH"
    chown root:root "\$SANDBOX_PATH" || echo "Warning: Failed to chown chrome-sandbox"
    chmod 4755 "\$SANDBOX_PATH" || echo "Warning: Failed to chmod chrome-sandbox"
    echo "Permissions set for \$SANDBOX_PATH"
else
    echo "Warning: chrome-sandbox binary not found. Sandbox may not function correctly."
fi

%changelog
* $(date '+%a %b %d %Y') ${MAINTAINER} ${VERSION}-1
- Initial package
EOF

# Build RPM package
echo "📦 Building RPM package..."
mkdir -p "${WORK_DIR}"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

RPM_FILE="$(pwd)/${ARCHITECTURE}/claude-desktop-${VERSION}-1${DISTRIBUTION}.$(uname -m).rpm"
if rpmbuild -bb \
    --define "_topdir ${WORK_DIR}" \
    --define "_rpmdir $(pwd)" \
    "${WORK_DIR}/claude-desktop.spec"; then
    echo "✓ RPM package built successfully at: $RPM_FILE"
    echo "🎉 Done! You can now install the RPM with: dnf install $RPM_FILE"
else
    echo "❌ Failed to build RPM package"
    exit 1
fi
