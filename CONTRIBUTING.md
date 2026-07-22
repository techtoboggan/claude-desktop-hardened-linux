# Contributing to Claude Desktop Hardened for Linux

Thanks for your interest in contributing! This project repackages Anthropic's **official** Claude Desktop for Linux `.deb` with a security-hardening layer. The application payload ships **unmodified** — we do not patch `app.asar` or inject code. The contribution surface is therefore the **bubblewrap sandbox wrapper**, the **build/packaging system**, and **supply-chain hardening**.

## Getting started

### Prerequisites

- Node.js 18-23 and npm
- Python 3.9+
- Root/sudo access (for `build.sh`)
- A supported distro (Fedora, Debian/Ubuntu, or Arch) or a container

### Building locally

```bash
git clone https://github.com/techtoboggan/claude-desktop-hardened-linux.git
cd claude-desktop-hardened-linux
sudo FORMAT=rpm ./build.sh   # or deb, arch
```

The build downloads the official Linux `.deb` (pinned by SHA256 in `CLAUDE_VERSION`), repackages it for the target distro with the sandbox launcher, and bundles the Claude Code CLI.

### Running tests

```bash
# Doctor integration tests
bash tests/test_doctor.sh

# Package smoke tests (run after building)
bash tests/test_package_contents.sh
```

## How to handle a new upstream version

Upstream version bumps are automated: the **Check Upstream Version** workflow detects a new official `.deb`, updates `CLAUDE_VERSION` (version + SHA256 pin), and the **Release** workflow builds and publishes. Because we repackage the official Linux build unmodified, upstream changes rarely break the build — there are no minified-JS patches to keep in sync anymore.

If a build *does* fail after a bump:

1. CI opens an issue titled "Build failure: Claude Desktop X.Y.Z" with diagnostics
2. Reproduce locally with `sudo FORMAT=rpm ./build.sh`
3. The failure is almost always in packaging (`lib/package-*.sh`, `packaging/`) or the sandbox launcher — not in the app payload
4. Open a PR with the fix

## Sandbox wrapper

The hardening is a [bubblewrap](https://github.com/containers/bubblewrap) launcher that runs the official app inside a namespace: read-only system, restricted device access, PID/UTS/cgroup isolation, and `$HOME` default-allow with credential/secret locations masked (`~/.ssh`, `~/.gnupg`, cloud creds, browser profiles, keyrings). Escape hatch: `CLAUDE_NO_SANDBOX=1`.

When changing sandbox behavior, verify the app still launches and that MCP servers / Cowork file access still work, then run `claude-desktop-hardened --doctor`.

## Pull request guidelines

- Keep PRs focused — one concern per PR
- Include test coverage for new functionality where practical
- Run the test suite and a local build before submitting
- Security-sensitive changes (sandbox policy, supply-chain pins) should explain the threat model in the PR description

## Reporting security issues

If you find a security vulnerability, please do **not** open a public issue. Instead, email the maintainer or use GitHub's private vulnerability reporting feature.

## Code of conduct

Be respectful and constructive. This is a community project maintained in spare time.
