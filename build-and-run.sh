#!/usr/bin/env bash
# Build this fork of Ghostty and run it.
#
#   ./build-and-run.sh               optimized build
#   ./build-and-run.sh --debug       debug build (quicker to compile, slow to run)
#   ./build-and-run.sh --install     build and install into $PREFIX (default
#                                    ~/.local) instead of running
#   ./build-and-run.sh -- [args...]  pass extra arguments to ghostty
#
# The split header is on by default; its settings (split-header-*) go in
# the normal Ghostty config. An official Ghostty build rejects options it
# doesn't know, so remove them if switching back.
#
# ---------------------------------------------------------------------------
# Dependencies
#
# This just wraps `zig build`, so anything needed to build upstream Ghostty
# from a Git checkout is needed here too. `nix/devShell.nix` is the
# authoritative list (it's what Ghostty's own CI builds against); the
# summary below is what actually matters for this script to succeed:
#
#   - zig, at the version pinned by `minimum_zig_version` in build.zig.zon
#     (0.16.0 as of this writing). Run `zig version` to check; most distro
#     packages lag behind, so you may need a manual install from
#     https://ziglang.org/download/.
#   - pkg-config, used by the build to find every library below.
#   - blueprint-compiler >= 0.16.0 (a *build-time* tool, not a library) --
#     compiles the .blp UI files under src/apprt/gtk/ui/, including this
#     fork's split-header.blp, into the .ui XML GTK actually loads.
#   - GTK4 + libadwaita development files (gtk4, libadwaita-1), and their
#     own dependencies' dev files: glib2, harfbuzz, freetype2, fontconfig,
#     oniguruma, bzip2, libxml2, zlib.
#   - Windowing system dev files -- at least one of:
#       X11:     libX11, libXcursor, libXext, libXi, libXinerama, libXrandr
#       Wayland: wayland, wayland-protocols (needs the wayland-scanner tool)
#   - gtk4-layer-shell -- optional, only needed for Wayland layer-shell
#     support (e.g. the quick terminal).
#
#   Fedora (dnf):
#     sudo dnf install zig pkgconf-pkg-config blueprint-compiler \
#       gtk4-devel libadwaita-devel gtk4-layer-shell-devel \
#       glib2-devel harfbuzz-devel freetype-devel fontconfig-devel \
#       oniguruma-devel bzip2-devel libxml2-devel zlib-devel \
#       libX11-devel libXcursor-devel libXext-devel libXi-devel \
#       libXinerama-devel libXrandr-devel wayland-devel wayland-protocols-devel
#
#   Debian/Ubuntu (apt): the same list with "-devel" swapped for "-dev"
#   (e.g. libgtk-4-dev, libadwaita-1-dev, libglib2.0-dev); `apt search
#   <name>` if one of these has drifted.
#
#   Not needed to build -- only at *runtime*, and only for this fork's
#   avatar / app-icon picker (its context menu shells out to these; see
#   set_app_icon_script and set_default_avatar_script below):
#     - python3 with Pillow (`python3-pillow`, or `pip install Pillow`) --
#       resizes a chosen image into every icon size Ghostty needs.
#     - python-xlib (`python3-xlib`) -- optional, only used to push the new
#       icon to already-open windows' taskbar entries on X11.
#     - ImageMagick's `convert` -- optional fallback resizer if PIL isn't
#       installed.
# ---------------------------------------------------------------------------
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

optimize=ReleaseFast
install=false
while [[ $# -gt 0 ]]; do
    case "$1" in
    --debug) optimize=Debug ;;
    --install) install=true ;;
    --)
        shift
        break
        ;;
    *) break ;;
    esac
    shift
done

config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/ghostty"

build_args=(-Doptimize="$optimize")

if ! $install; then
    # Pinning the version stops the build stamping in the git commit, which
    # otherwise forces a full recompile after every commit while iterating.
    # Installed builds skip the pin so `ghostty +version` reports the real
    # upstream version plus the branch and commit they were built from.
    version="1.3.2-sutts"
    zig build "${build_args[@]}" -Dversion-string="$version" -Dlib-version-string="$version"

    # Run as a separate instance so the window isn't handed to an
    # already-running official Ghostty, which has no split header support.
    exec ./zig-out/bin/ghostty --gtk-single-instance=false "$@"
fi

# The prefix is baked into the desktop file, D-Bus service and systemd unit,
# so launchers point at the installed binary rather than zig-out.
prefix="${PREFIX:-$HOME/.local}"
zig build -p "$prefix" "${build_args[@]}"
echo "installed to $prefix"

if [[ -f "$config_dir/app-icon.png" ]]; then
    python3 -c "
import os, sys
from PIL import Image
src = '$config_dir/app-icon.png'
prefix = '$prefix'
base = os.path.join(prefix, 'share', 'icons', 'hicolor')
if os.path.isfile(src):
    img = Image.open(src).convert('RGBA')
    for s in [16, 32, 48, 64, 128, 256, 512]:
        d = os.path.join(base, f'{s}x{s}', 'apps')
        os.makedirs(d, exist_ok=True)
        img.resize((s, s), Image.Resampling.LANCZOS).save(os.path.join(d, 'com.mitchellh.ghostty.png'), 'PNG')
" 2>/dev/null || true
    gtk-update-icon-cache -f -t "$prefix/share/icons/hicolor" 2>/dev/null || true
    echo "preserved custom app icon"
fi

systemctl --user daemon-reload 2>/dev/null || true

hash -r
if [[ "$(command -v ghostty)" != "$prefix/bin/ghostty" ]]; then
    echo "warning: 'ghostty' on PATH is $(command -v ghostty || echo missing), not $prefix/bin/ghostty" >&2
fi
echo "quit any running Ghostty windows so new ones use this build"
