***THIS IS AN UNOFFICIAL BUILD SCRIPT!***

If you run into an issue, [open an issue here](https://github.com/techtoboggan/claude-desktop-hardened-linux/issues). Don't bug Anthropic about it — they already have enough on their plates.

# Claude Desktop for Linux (Hardened)

A security-focused Linux build of Claude Desktop. Downloads the official release, applies bubblewrap sandboxing, credential redaction, and permission-gated Computer Use — then packages it for Fedora, Debian/Ubuntu, and Arch.

## Features

- **Cowork / Local Agent Mode** — sandboxed via [bubblewrap](https://github.com/containers/bubblewrap) with read-only filesystem, tmpfs over sensitive directories, credential redaction, and environment allowlisting
- **Computer Use** — screenshot, click, type, and scroll automation for both X11 and Wayland, gated by a per-session permission dialog (no auto-grant)
- **MCP** (Model Context Protocol) — configure servers in `~/.config/Claude/claude_desktop_config.json`
- **Ctrl+Alt+Space** quick entry popup
- **System tray** with auto-inverted icons for dark themes
- **Native Wayland support** — auto-detected, with proper taskbar pinning, window grouping, and Ozone platform hints
- **Bundled Claude Code CLI** — `claude` command available system-wide after install
- **Diagnostic tool** — `claude-desktop-hardened --doctor` checks your system for missing dependencies and misconfigurations

## Security model

This project treats Claude's agentic capabilities as a security boundary. Every feature that touches the host system is sandboxed, logged, or gated behind user confirmation.

### Cowork sandboxing

When Cowork spawns a Claude Code session, it runs inside a [bubblewrap](https://github.com/containers/bubblewrap) sandbox with a default-deny filesystem policy:

- **Minimal rootfs** — only `/usr`, `/lib`, `/lib64`, and select `/etc` files are mounted read-only. The agent cannot see your home directory, browser data, password managers, or other users' files.
- **Writable mounts** limited to the working directory, session data, and `~/.config/Claude`
- **Resource limits** via `systemd-run` — 4GB memory, 200% CPU (2 cores), 512 max tasks to prevent runaway processes and fork bombs
- `--die-with-parent` ensures cleanup if the parent process exits
- Environment variables filtered through an allowlist (HOME, PATH, DISPLAY, XDG_*, etc.)
- **No unsandboxed fallback** — if bubblewrap is not found, sessions refuse to start

Bubblewrap is a **hard dependency** — if you're using this package, you get sandboxing. That's the point.

### Network access

Sandboxed sessions have **full network access**. Claude Code needs HTTPS to `api.anthropic.com` to function, and isolating the network would break core functionality. This means the agent can theoretically reach internal services on your network. If you run services on localhost or your LAN that accept unauthenticated requests, be aware of this. We may add network policy support (via nftables or a proxy) in a future release.

### Computer Use permissions

On other platforms, Computer Use permissions are auto-granted. Here, every permission request shows a native dialog:

- **Screen Recording** — screenshot capture via `grim` (Wayland) or `scrot` (X11)
- **Input Automation** — click/type/scroll via `ydotool` (Wayland) or `xdotool` (X11)
- **Window Listing** — via `hyprctl`/`swaymsg` (Wayland) or `wmctrl` (X11)

Grants are session-only — they reset when you close Claude Desktop. All Computer Use actions are logged to the transcript store with credential redaction applied.

### Credential redaction

All session transcripts are scrubbed before hitting disk:

- Bearer tokens, API keys (AWS, GitHub, Anthropic, OpenAI, Slack, Stripe, npm, PyPI)
- JWTs, OAuth tokens, private keys, database connection strings
- Google Cloud service account key IDs
- Generic secrets in environment-style assignments
- Sensitive environment variables filtered from subprocess environments

### Electron sandbox

The `chrome-sandbox` binary is set to `4755 root:root` (setuid) during post-install. This preserves Electron's multi-process sandbox — the renderer runs in a restricted namespace even if the main process is compromised.

### Supply chain integrity

- nupkg SHA256 verified against the pin in `CLAUDE_VERSION`
- Release packages verified via `SHA256SUMS` with optional GPG signature
- Source scanned for trojan source / Unicode attacks on every PR and push
- Dependency vulnerability and malware scanning via OWASP depscan and vet
- npm install runs with `--ignore-scripts` to prevent arbitrary code execution during build
- CycloneDX SBOM attached to every release
- Automated upstream version monitoring creates PRs for new releases

---

## Installation

### Fedora (recommended)

Available from [Fedora COPR](https://copr.fedorainfracloud.org/coprs/techtoboggan/claude-desktop-hardened/) for Fedora 43 and 44:

```bash
sudo dnf copr enable techtoboggan/claude-desktop-hardened
sudo dnf install claude-desktop-hardened
```

Updates automatically with `sudo dnf upgrade`.

### Arch Linux (AUR)

```bash
yay -S claude-desktop-hardened-bin
```

Or manually:

```bash
git clone https://aur.archlinux.org/claude-desktop-hardened-bin.git
cd claude-desktop-hardened-bin
makepkg -si
```

### Debian / Ubuntu (APT)

```bash
curl -fsSL https://techtoboggan.github.io/claude-desktop-hardened-linux/pubkey.asc | sudo gpg --dearmor -o /usr/share/keyrings/claude-desktop-hardened.gpg
echo "deb [signed-by=/usr/share/keyrings/claude-desktop-hardened.gpg] https://techtoboggan.github.io/claude-desktop-hardened-linux stable main" | sudo tee /etc/apt/sources.list.d/claude-desktop-hardened.list
sudo apt update
sudo apt install claude-desktop-hardened
```

### Quick install (any distro)

```bash
curl -fsSL https://raw.githubusercontent.com/techtoboggan/claude-desktop-hardened-linux/main/install.sh | bash
```

Detects your distro, downloads the latest release, and installs it.

### Manual install

Download the latest package from [Releases](https://github.com/techtoboggan/claude-desktop-hardened-linux/releases):

```bash
# Fedora / RHEL / Rocky
sudo dnf install claude-desktop-hardened-*.rpm

# Debian / Ubuntu
sudo dpkg -i claude-desktop-hardened_*.deb && sudo apt-get install -f

# Arch Linux
sudo pacman -U claude-desktop-hardened-*.pkg.tar.zst
```

### Build from source

```bash
git clone https://github.com/techtoboggan/claude-desktop-hardened-linux.git
cd claude-desktop-hardened-linux

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

| Family | Distros | Package | Repo |
|--------|---------|---------|------|
| RPM | Fedora 43/44 | `.rpm` | [COPR](https://copr.fedorainfracloud.org/coprs/techtoboggan/claude-desktop-hardened/) |
| RPM | RHEL, CentOS, Rocky, AlmaLinux, Nobara | `.rpm` | manual |
| DEB | Debian, Ubuntu, Pop!_OS, Linux Mint | `.deb` | manual |
| Arch | Arch Linux, Manjaro, EndeavourOS, CachyOS | `.pkg.tar.zst` | [AUR](https://aur.archlinux.org/packages/claude-desktop-hardened-bin) |
| NixOS | [k3d3/claude-desktop-linux-flake](https://github.com/k3d3/claude-desktop-linux-flake) | Nix flake | external |

x86_64 only.

---

## Post-install

### Verify your setup

```bash
claude-desktop-hardened --doctor
```

Checks Electron, chrome-sandbox permissions, bubblewrap, display server, Computer Use tools, MCP config, Claude Code CLI, Node.js, and keyring availability.

### Computer Use tools (optional)

Install the tools for your display server to enable Computer Use:

**Wayland** (GNOME, KDE Plasma, Sway, Hyprland):
```bash
# Fedora
sudo dnf install grim slurp wl-clipboard ydotool wlr-randr

# Arch
sudo pacman -S grim slurp wl-clipboard ydotool wlr-randr
```

**X11**:
```bash
# Fedora
sudo dnf install wmctrl xdotool scrot xclip xrandr

# Arch
sudo pacman -S wmctrl xdotool scrot xclip xorg-xrandr
```

### MCP servers

Configure MCP servers in `~/.config/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "example": {
      "command": "node",
      "args": ["/path/to/server.js"]
    }
  }
}
```

---

## How it works

Claude Desktop ships as a Windows `.exe` installer containing an Electron app. The build script:

1. **Downloads** the pinned nupkg (version + SHA256 verified from `CLAUDE_VERSION`)
2. **Extracts icons** from the Windows exe (16px through 256px)
3. **Replaces native modules** — swaps Windows/macOS native addons with Linux stubs for keyboard constants, platform detection, and Cowork session management
4. **Installs Cowork stubs** — a process orchestrator for spawning sandboxed Claude Code CLI sessions with credential redaction, file watching, session persistence, and IPC handling
5. **Installs Computer Use modules** — display-server-aware screenshot, window listing, and input automation with a permission dialog layer
6. **Patches platform gating** — modular patches in `patches/` surgically modify 8 locations in the minified JS to accept Linux as a supported platform
7. **Patches window decorations** — switches from macOS `hiddenInset` to Electron CSD with transparent title bar overlay
8. **Injects startup code** — sets the window icon, fixes the system tray, sets Wayland `app_id`, and registers permission-gated Computer Use handlers
9. **Inverts tray icons** for dark Linux system trays
10. **Bundles Claude Code CLI** from npm
11. **Packages** as RPM, DEB, or Arch with post-install hooks for icon caches, desktop database updates, and chrome-sandbox setuid

### Patch architecture

Platform patches are modular — each lives in its own file under `patches/`:

| Patch | Purpose |
|-------|---------|
| `patch_platform_gating.py` | Accept Linux in platform check functions |
| `patch_vm_manifest.py` | Add Linux entries to VM image manifest |
| `patch_platform_constants.py` | Include Linux in `isSupportedPlatform` |
| `patch_enterprise_config.py` | Ensure VM features aren't forced off |
| `patch_api_headers.py` | Spoof platform headers for feature checks |
| `patch_binary_manager.py` | Add Linux to `getHostPlatform()` |
| `patch_binary_resolution.py` | Find system-installed Claude CLI |
| `inject_cowork_init.py` | Wire up Cowork lifecycle hooks |

This makes version bumps easier — when upstream renames minified symbols, you update one file instead of a monolithic script.

---

## Version pinning

`CLAUDE_VERSION` pins the exact Claude Desktop release:

- **Line 1**: version string (e.g., `1.1.9134`)
- **Line 2**: SHA256 of the nupkg for supply chain verification

A daily CI workflow checks for new upstream releases and creates a PR with the updated version and hash. To update manually: change line 1, update the hash, commit and push to `main`. The release workflow builds, tags, and publishes automatically.

---

## License

Build scripts and stubs are dual-licensed under [MIT](LICENSE-MIT) and [Apache 2.0](LICENSE-APACHE).

The Claude Desktop application itself is covered by [Anthropic's Consumer Terms](https://www.anthropic.com/legal/consumer-terms).
