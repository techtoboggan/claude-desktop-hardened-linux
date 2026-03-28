#!/usr/bin/env python3
"""
Generate all packaging specs from a single source of truth (metadata.json).

Outputs:
  - rpm/claude-desktop-hardened.spec.in     (build-from-source RPM)
  - rpm/claude-desktop-hardened.copr.spec.in (binary repackage for COPR)
  - deb/control.in                          (Debian/Ubuntu)
  - arch/PKGBUILD.in                        (Arch Linux)

Usage:
  python3 packaging/generate-specs.py
"""

import json
import os

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

with open(os.path.join(SCRIPT_DIR, 'metadata.json')) as f:
    META = json.load(f)

NAME = META['name']


def write(path, content):
    full = os.path.join(SCRIPT_DIR, path)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, 'w') as f:
        f.write(content)
    print(f'  [ok] {path}')


# ---------------------------------------------------------------------------
# Shared fragments
# ---------------------------------------------------------------------------

def rpm_post_script():
    return f"""\
gtk-update-icon-cache -f -t %{{_datadir}}/icons/hicolor 2>/dev/null || :
update-desktop-database %{{_datadir}}/applications 2>/dev/null || :
chmod +x %{{_bindir}}/claude 2>/dev/null || :
# Set chrome-sandbox setuid for Electron sandbox
for p in /usr/lib64/{NAME}/app.asar.unpacked/node_modules/electron/dist/chrome-sandbox \\
         "$(dirname "$(command -v electron 2>/dev/null)")/../lib/node_modules/electron/dist/chrome-sandbox"; do
  if [ -f "$p" ]; then chown root:root "$p" && chmod 4755 "$p"; break; fi
done || :"""


def rpm_postun_script():
    return """\
gtk-update-icon-cache -f -t %{_datadir}/icons/hicolor 2>/dev/null || :
update-desktop-database %{_datadir}/applications 2>/dev/null || :"""


def rpm_files_list():
    return '\n'.join(META['files'])


def rpm_suggests():
    x11 = ', '.join(META['suggests']['x11'])
    wayland = ', '.join(META['suggests']['wayland'])
    return f"""\
# X11 Computer Use tools
Suggests:       {x11}
# Wayland Computer Use tools
Suggests:       {wayland}"""


# ---------------------------------------------------------------------------
# RPM spec (build from source)
# ---------------------------------------------------------------------------

def generate_rpm_spec():
    deps = ', '.join(META['depends']['rpm'])
    recommends = ', '.join(META['recommends'])
    return f"""\
Name:           {NAME}
Version:        @@VERSION@@
Release:        1
Summary:        {META['summary']}
License:        {META['license']}
AutoReqProv:    no
URL:            {META['url']}
BuildArch:      @@ARCHITECTURE@@
Requires:       {deps}
Recommends:     {recommends}
{rpm_suggests()}
Provides:       claude-desktop = %{{version}}-%{{release}}
Conflicts:      claude-desktop

%description
{META['description']}

%install
mkdir -p %{{buildroot}}/usr/lib64/%{{name}}
mkdir -p %{{buildroot}}/usr/bin
mkdir -p %{{buildroot}}/usr/share/applications
mkdir -p %{{buildroot}}/usr/share/icons

# Copy files from the staging area
cp -r @@INSTALL_DIR@@/lib/%{{name}}/* %{{buildroot}}/usr/lib64/%{{name}}/
cp -r @@INSTALL_DIR@@/bin/* %{{buildroot}}/usr/bin/
cp -r @@INSTALL_DIR@@/share/applications/* %{{buildroot}}/usr/share/applications/
cp -r @@INSTALL_DIR@@/share/icons/* %{{buildroot}}/usr/share/icons/
if [ -d "@@INSTALL_DIR@@/share/%{{name}}" ]; then
    mkdir -p %{{buildroot}}/usr/share/%{{name}}
    cp -r @@INSTALL_DIR@@/share/%{{name}}/* %{{buildroot}}/usr/share/%{{name}}/
fi

%files
{rpm_files_list()}

%post
{rpm_post_script()}

%postun
{rpm_postun_script()}

%changelog
* @@DATE@@ @@MAINTAINER@@ @@VERSION@@-1
- Package build
"""


# ---------------------------------------------------------------------------
# COPR spec (binary repackage)
# ---------------------------------------------------------------------------

def generate_copr_spec():
    copr_deps = [d for d in META['depends']['rpm'] if d not in ('npm', 'p7zip')]
    recommends = ', '.join(META['recommends'])
    return f"""\
# Disable build-id checks and stripping — this is a binary repackage
%global _missing_build_ids_terminate_build 0
%global _enable_debug_packages 0
%global debug_package %{{nil}}
%global __os_install_post %{{nil}}
%global __strip /bin/true

Name:           {NAME}
Version:        ${{VERSION}}
Release:        1%{{?dist}}
Summary:        {META['summary']}
License:        {META['license']}
URL:            {META['url']}
Source0:        {NAME}-${{VERSION}}.tar.gz
AutoReqProv:    no
BuildArch:      x86_64
Requires:       {', '.join(copr_deps)}
Recommends:     {recommends}
{rpm_suggests()}
Provides:       claude-desktop = %{{version}}-%{{release}}
Conflicts:      claude-desktop

%description
{META['description']}

%prep
%setup -c -T
tar xzf %{{SOURCE0}}

%install
cp -a . %{{buildroot}}/

%post
{rpm_post_script()}

%postun
{rpm_postun_script()}

%files
{rpm_files_list()}
"""


# ---------------------------------------------------------------------------
# DEB control
# ---------------------------------------------------------------------------

def generate_deb_control():
    deps = ', '.join(META['depends']['deb'])
    recommends = ', '.join(META['recommends'])
    suggests_x11 = ', '.join(META['suggests']['x11']).replace('xrandr', 'x11-xserver-utils')
    suggests_wayland = ', '.join(META['suggests']['wayland'])
    return f"""\
Package: {NAME}
Version: @@VERSION@@
Architecture: @@DEB_ARCH@@
Maintainer: Claude Desktop Linux Maintainers
Depends: {deps}
Recommends: {recommends}
Suggests: {suggests_x11},
 {suggests_wayland}
Provides: claude-desktop
Conflicts: claude-desktop
Section: utils
Priority: optional
Homepage: {META['url']}
Description: {META['summary']}
 {META['description']}
"""


# ---------------------------------------------------------------------------
# Arch PKGBUILD
# ---------------------------------------------------------------------------

def generate_arch_pkgbuild():
    deps = ' '.join(f"'{d}'" for d in META['depends']['arch'])
    optdeps = '\n'.join(f"            '{d}'" for d in META['optdepends_arch'])
    return f"""\
# Maintainer: {META['maintainer']}
pkgname={NAME}
pkgver=@@VERSION@@
pkgrel=1
pkgdesc="{META['summary']} — bubblewrap sandboxing, credential redaction"
arch=('x86_64' 'aarch64')
url="{META['url']}"
license=('custom:Proprietary')
depends=({deps})
optdepends=({optdeps})
provides=('claude-desktop')
conflicts=('claude-desktop' 'claude-desktop-bin')

# This PKGBUILD operates on a pre-built staging directory.
# Run the build pipeline first, then makepkg from the staging dir.

package() {{
    # Copy from the staging area prepared by the build pipeline
    cp -r "${{srcdir}}/staged/usr" "${{pkgdir}}/usr"

    # Fix chrome-sandbox permissions
    local sandbox="${{pkgdir}}/usr/lib/{NAME}/app.asar.unpacked/node_modules/electron/dist/chrome-sandbox"
    if [ -f "$sandbox" ]; then
        chmod 4755 "$sandbox"
    fi
}}
"""


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if __name__ == '__main__':
    print('[generate-specs] Generating from metadata.json...')
    write('rpm/claude-desktop-hardened.spec.in', generate_rpm_spec())
    write('rpm/claude-desktop-hardened.copr.spec.in', generate_copr_spec())
    write('deb/control.in', generate_deb_control())
    write('arch/PKGBUILD.in', generate_arch_pkgbuild())
    print('[generate-specs] Done!')
