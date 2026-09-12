#!/usr/bin/env bash
# Build this fork of Ghostty and run it with the split header enabled.
#
#   ./build-and-run.sh               optimized build
#   ./build-and-run.sh --debug       debug build (quicker to compile, slow to run)
#   ./build-and-run.sh --install     build and install into $PREFIX (default
#                                    ~/.local) instead of running
#   ./build-and-run.sh -- [args...]  pass extra arguments to ghostty
#
# Split header settings live in $SPLIT_HEADER_CONFIG (default
# ~/.config/ghostty/split-header.conf), created with defaults on first run.
# They're kept out of the main Ghostty config because an official Ghostty
# build would reject the options it doesn't know. --install adds an optional
# include of that file to the main config, since the installed launcher
# can't pass --config-file itself.
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
config="${SPLIT_HEADER_CONFIG:-$config_dir/split-header.conf}"
if [[ ! -f "$config" ]]; then
    avatar_dir="$config_dir/avatars"
    if [[ -d "$HOME/Projects/waveterm/avatar-gallery/images" ]]; then
        avatar_dir="$HOME/Projects/waveterm/avatar-gallery/images"
    fi
    mkdir -p "$(dirname "$config")"
    cat >"$config" <<EOF
split-header = true
split-header-style = portrait
split-header-avatar-dir = $avatar_dir
EOF
    echo "created $config"
fi

# Pinning the version stops the build stamping in the git commit and dirty
# state, which otherwise forces a full recompile after every commit or edit.
version="1.3.2-sutts"
build_args=(-Doptimize="$optimize" -Dversion-string="$version" -Dlib-version-string="$version")

if ! $install; then
    zig build "${build_args[@]}"

    # Run as a separate instance so the window isn't handed to an
    # already-running official Ghostty, which has no split header support.
    exec ./zig-out/bin/ghostty --gtk-single-instance=false --config-file="$config" "$@"
fi

# The prefix is baked into the desktop file, D-Bus service and systemd unit,
# so launchers point at the installed binary rather than zig-out.
prefix="${PREFIX:-$HOME/.local}"
zig build -p "$prefix" "${build_args[@]}"
echo "installed to $prefix"

# Ghostty 1.3 reads config.ghostty, falling back to the older plain "config".
main_config="$config_dir/config.ghostty"
if [[ ! -f "$main_config" && -f "$config_dir/config" ]]; then
    main_config="$config_dir/config"
fi
include="config-file = ?$config"
if ! grep -qxF "$include" "$main_config" 2>/dev/null; then
    mkdir -p "$(dirname "$main_config")"
    printf '\n# Split header settings (Sutts build only; remove if switching back\n# to an official Ghostty, which rejects them).\n%s\n' "$include" >>"$main_config"
    echo "added split header include to $main_config"
fi

systemctl --user daemon-reload 2>/dev/null || true

hash -r
if [[ "$(command -v ghostty)" != "$prefix/bin/ghostty" ]]; then
    echo "warning: 'ghostty' on PATH is $(command -v ghostty || echo missing), not $prefix/bin/ghostty" >&2
fi
echo "quit any running Ghostty windows so new ones use this build"
