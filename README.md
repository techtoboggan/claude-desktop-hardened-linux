***THIS IS AN UNOFFICIAL BUILD SCRIPT!***

If you run into an issue, [open an issue here](https://github.com/techtoboggan/claude-desktop-linux/issues). Don't bug Anthropic about it — they already have enough on their plates.

# Claude Desktop for Linux

Builds and packages Claude Desktop for Linux from the official Windows release, with full support for:

- **Cowork / Local Agent Mode** — sandboxed via [bubblewrap](https://github.com/containers/bubblewrap) when available, or direct execution
- **MCP** (Model Context Protocol) — configure in `~/.config/Claude/claude_desktop_config.json`
- **Ctrl+Alt+Space** quick entry popup
- **System tray** with auto-inverted icons for dark themes
- **Native Wayland support** — proper taskbar pinning, window grouping, and icons
- **Bundled Claude Code CLI** — `claude` command available system-wide after install

---

## Installation

### Quick install

```bash
curl -fsSL https://raw.githubusercontent.com/techtoboggan/claude-desktop-linux/main/install.sh | bash
```

Detects your distro, downloads the latest release, and installs it.

### Fedora (COPR)

```bash
sudo dnf copr enable techtoboggan/claude-desktop
sudo dnf install claude-desktop
```

Updates automatically with `sudo dnf upgrade`.

### Manual install

Download the latest package for your distro from [Releases](https://github.com/techtoboggan/claude-desktop-linux/releases):

```bash
# Fedora / RHEL / Rocky
sudo dnf install claude-desktop-*.rpm

# Debian / Ubuntu
sudo dpkg -i claude-desktop_*.deb && sudo apt-get install -f

# Arch Linux
sudo pacman -U claude-desktop-*.pkg.tar.zst
```

### Build from source

```bash
git clone https://github.com/techtoboggan/claude-desktop-linux.git
cd claude-desktop-linux

# Auto-detects your distro and builds the right package
sudo ./build.sh

# Or specify a format explicitly
sudo FORMAT=rpm ./build.sh
sudo FORMAT=deb ./build.sh
sudo FORMAT=arch ./build.sh
```

Requires Node.js >= 18, npm, and root/sudo access. Build dependencies are installed automatically.

---

## Supported distros

| Family | Distros | Package |
|--------|---------|---------|
| RPM | Fedora, RHEL, CentOS, Rocky, AlmaLinux, Nobara | `.rpm` |
| DEB | Debian, Ubuntu, Pop!_OS, Linux Mint | `.deb` |
| Arch | Arch Linux, Manjaro, EndeavourOS, CachyOS | `.pkg.tar.zst` |
| NixOS | [k3d3/claude-desktop-linux-flake](https://github.com/k3d3/claude-desktop-linux-flake) | Nix flake |

x86_64 only.

---

## How it works

Claude Desktop ships as a Windows `.exe` installer containing an Electron app in an `.asar` archive. The build script:

1. **Downloads** the pinned nupkg (version + SHA256 verified from `CLAUDE_VERSION`)
2. **Extracts icons** from the Windows exe (16px through 256px) and installs them to hicolor
3. **Replaces native modules** — swaps Windows/macOS native addons (`claude-native`, `claude-swift`) with Linux stubs that provide keyboard constants, platform detection, and Cowork session management
4. **Installs Cowork stubs** — a full process orchestrator for spawning Claude Code CLI sessions with bubblewrap sandboxing, credential redaction, file watching, session persistence, and IPC handling
5. **Patches platform gating** (`enable-cowork.py`) — surgically modifies 7 locations in the minified JS:
   - Platform gating functions → accept Linux
   - VM image manifest → add dummy Linux entries so the UI enables Cowork
   - Platform constants → include Linux as a supported platform
   - Enterprise config → ensure `secureVmFeaturesEnabled` isn't forced off
   - API headers → spoof platform for server-side feature checks
   - Binary manager → add Linux to `getHostPlatform()`
   - Binary resolution → find system-installed `claude` CLI on Linux
6. **Patches window decorations** — switches from macOS `hiddenInset` to Electron CSD (client-side decorations) with transparent title bar overlay
7. **Injects startup code** — hides the menu bar, sets the window icon, fixes the system tray (singleton pattern to prevent D-Bus StatusNotifierItem re-export failures), sets Wayland `app_id` via `app.setDesktopName()`, and registers stub handlers for macOS-only eipc interfaces (`ComputerUseTcc`)
8. **Inverts tray icons** to white using ImageMagick for dark Linux system trays
9. **Bundles Claude Code CLI** from npm and creates a system-wide `claude` wrapper
10. **Packages** as RPM, DEB, or Arch with post-install hooks for icon caches, desktop database updates, and chrome-sandbox setuid permissions

### Cowork on Linux

On macOS/Windows, Cowork runs Claude Code inside a VM (Apple Virtualization Framework / Hyper-V). On Linux, the stubs in `stubs/` replace this with:

- **Bubblewrap sandboxing** (when `/usr/bin/bwrap` is available) — read-only bind mount of `/`, writable bind mounts for the working directory and session data, tmpfs over sensitive directories (`.ssh`, `.gnupg`, `.aws`, `.kube`, `.docker`), `--die-with-parent` for cleanup
- **Direct host execution** as a fallback when bubblewrap isn't installed
- **Credential redaction** in all session transcripts (API keys, tokens, JWTs, private keys)
- **Path safety checks** blocking traversal attacks and access to sensitive dotfiles
- **Environment variable allowlisting** — only passes through safe vars (HOME, PATH, DISPLAY, WAYLAND_DISPLAY, XDG_*, etc.)
- **Session persistence** to `~/.config/Claude/local-agent-mode-sessions/` with JSONL transcripts

Install `bubblewrap` for sandboxed sessions (recommended):
```bash
sudo dnf install bubblewrap   # Fedora
sudo apt install bubblewrap   # Ubuntu/Debian
sudo pacman -S bubblewrap     # Arch
```

---

## Version pinning

`CLAUDE_VERSION` pins the exact Claude Desktop release:

- **Line 1**: version string (e.g., `1.1.9134`)
- **Line 2**: SHA256 of the nupkg for supply chain verification

To update: change line 1, optionally update the hash, commit and push to `main`. The release workflow builds, tags, and publishes automatically.

---

## Supply chain security

- All CI actions are pinned to commit SHAs
- nupkg SHA256 verified against the pin in `CLAUDE_VERSION`
- Source scanned for trojan source / Unicode attacks on every PR and push
- Dependency vulnerability and malware scanning via OWASP depscan and vet
- CycloneDX SBOM attached to every release

---

## License

Build scripts and stubs are dual-licensed under [MIT](LICENSE-MIT) and [Apache 2.0](LICENSE-APACHE).

The Claude Desktop application itself is covered by [Anthropic's Consumer Terms](https://www.anthropic.com/legal/consumer-terms).
