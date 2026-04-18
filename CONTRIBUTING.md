# Contributing to Claude Desktop Hardened for Linux

Thanks for your interest in contributing! This project repackages the official Claude Desktop for Linux with security hardening, so the contribution surface is primarily around the build system, patches, stubs, and packaging.

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

### Running tests

```bash
# JavaScript unit tests (credential classifier, path safety, computer use, bwrap, session store)
node tests/test_credential_classifier.js
node tests/test_path_safety.js
node tests/test_computer_use.js
node tests/test_bwrap_command.js
node tests/test_session_store.js

# Patch system tests
python3 tests/test_patches.py

# Doctor integration tests
bash tests/test_doctor.sh

# Package smoke tests (run after building)
bash tests/test_package_contents.sh
```

## How to update patches for a new upstream version

When Claude Desktop releases a new version, the minified JS may change — causing patches to fail. Here's how to fix them:

1. The CI will open an issue titled "Build failure: Claude Desktop X.Y.Z" with diagnostics
2. Download the new nupkg and extract it (the build script does this automatically)
3. Look at the build log to see which patch(es) failed
4. Each patch in `patches/` targets specific patterns in the minified JS — update the regex or string match to find the new symbol names
5. Test your fix:
   ```bash
   # Quick validation that patches apply and produce valid JS
   sudo FORMAT=rpm ./build.sh 2>&1 | grep -E '\[OK\]|\[FAIL\]'
   ```
6. Run `node --check` on the patched `index.js` to verify syntax
7. Open a PR with the patch update

### Patch architecture

Each patch file in `patches/` is a self-contained Python script that modifies one aspect of the minified JS:

| Patch | What it does |
|-------|-------------|
| `patch_platform_gating.py` | Accept Linux in platform check functions |
| `patch_vm_manifest.py` | Add Linux entries to VM image manifest |
| `patch_platform_constants.py` | Include Linux in `isSupportedPlatform` |
| `patch_enterprise_config.py` | Ensure VM features aren't forced off |
| `patch_api_headers.py` | Spoof platform headers for feature checks |
| `patch_binary_manager.py` | Add Linux to `getHostPlatform()` |
| `patch_binary_resolution.py` | Find system-installed Claude CLI |
| `inject_cowork_init.py` | Wire up Cowork lifecycle hooks |

Patches are applied in order by `lib/patch.sh`. Each patch validates its own success and prints `[OK]` or `[FAIL]`. After all patches run, `node --check` verifies the result is syntactically valid JS.

## Cowork stubs

The `stubs/cowork/` directory contains the session management layer:

- `index.js` — main entry, session lifecycle
- `session_orchestrator.js` — spawns sandboxed Claude Code CLI sessions
- `credential_classifier.js` — regex-based credential redaction
- `computer_use.js` — display-server-aware screenshot/click/type
- `computer_use_permission.js` — native permission dialogs
- `path_safety.js` — blocklist for sensitive directories

When modifying stubs, run the corresponding test file to verify your changes.

### Environment variable passthrough

Env-var passthrough from the user's shell to Cowork-sandboxed Claude Code sessions is controlled by the `ENV_ALLOWLIST` `Set` at the top of `stubs/claude-swift-stub/index.js`. Anything not in that set gets stripped by `filterEnv()` before the CLI is spawned.

If you're adding a new user-facing integration (a new model provider, a new upstream feature that reads an env var), you **must** add the relevant variable names to `ENV_ALLOWLIST` *and* mention them in the README's ["Using a custom model backend"](../README.md#using-a-custom-model-backend) section. A test at `tests/test_bwrap_command.js` parses the allowlist from source and asserts the `ANTHROPIC_*` SDK vars are present — extend that test when you add new required names, so the next upstream bump doesn't silently drop them.

Do **not** add cloud credentials (`AWS_*`, `GOOGLE_*`, `AZURE_*`) to the default allowlist — those have broader scope than just the model backend. Document them as opt-in in the README's "Bedrock / Vertex" subsection instead.

## Pull request guidelines

- Keep PRs focused — one concern per PR
- Include test coverage for new functionality
- Run the full test suite before submitting
- If your change touches patches, verify the build completes and `node --check` passes
- Security-sensitive changes should explain the threat model in the PR description

## Reporting security issues

If you find a security vulnerability, please do **not** open a public issue. Instead, email the maintainer or use GitHub's private vulnerability reporting feature.

## Code of conduct

Be respectful and constructive. This is a community project maintained in spare time.
