#!/usr/bin/env bash
# Build this fork of Ghostty and run it with the split header enabled.
#
#   ./build-and-run.sh               optimized build
#   ./build-and-run.sh --debug       debug build (quicker to compile, slow to run)
#   ./build-and-run.sh -- [args...]  pass extra arguments to ghostty
#
# Split header settings live in $SPLIT_HEADER_CONFIG (default
# ~/.config/ghostty/split-header.conf), created with defaults on first run.
# They're kept out of the main Ghostty config because an official Ghostty
# build would reject the options it doesn't know.
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

optimize=ReleaseFast
if [[ "${1:-}" == "--debug" ]]; then
    optimize=Debug
    shift
fi
if [[ "${1:-}" == "--" ]]; then
    shift
fi

config="${SPLIT_HEADER_CONFIG:-$HOME/.config/ghostty/split-header.conf}"
if [[ ! -f "$config" ]]; then
    avatar_dir="$HOME/.config/ghostty/avatars"
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

zig build -Doptimize="$optimize"

# Run as a separate instance so the window isn't handed to an already-running
# official Ghostty, which has no split header support.
exec ./zig-out/bin/ghostty --gtk-single-instance=false --config-file="$config" "$@"
